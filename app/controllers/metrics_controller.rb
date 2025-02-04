class MetricsController < ApplicationController
  include AuthorizationHelper
  include AssignmentHelper
  include MetricsHelper

  def action_allowed?
    current_user_has_instructor_privileges?
  end

  # This populates the database fields required to display user contributions in the view_team for grades heatgrid. 
  # It executes a query for all link submissions for an entire assignment, and runs the necessary queries to enable the 
  # "Github metrics" link on the list_assignments page.
  def query_assignment_statistics
    @assignment = Assignment.find(params[:id])
    teams = @assignment.teams
    teams.each do |team|
      topic_identifier, topic_name, users_for_curr_team, participants = get_data_for_list_submissions(team)
      github_metrics_for_submission(participants.first.id) unless participants.first.nil?
    end
    redirect_to controller: 'assignments', action: 'list_submissions', id: @assignment.id
  end

  # render the view_github_metrics page, which displays detailed metrics for a single team of participants.
  # Shows two charts, a barchart timeline, and a piechart of total contributions by team member, as well as pull request
  # statistics if available
  def show
    github_metrics_for_submission(params[:id])
  end

  # Authorize with token to use Github API with a higher rate limit of 5000 requests per hour. 
  # An unauthorized user only has 60 requests per hour limit, which is not sufficient.
  def authorize_github
    redirect_to "https://github.com/login/oauth/authorize?client_id=#{GITHUB_CONFIG['client_key']}"
  end

  # Master query method that runs a query based on links contained within a single team's submission. Sets up instance
  # variables, then passes control to retrieve_github_data to handle the logic for the individual links. Finally, store
  # a small subset of data as Metrics in the metrics table containing participants, their total contribution,
  # (in number of commits), their github email, and a reference to their User account (if mapping exists or can be determined)
  def github_metrics_for_submission(id)
    # redirect_to authorize_github if github_access_token is not present.
    if session["github_access_token"].nil?
      session["participant_id"] = id 
      session["assignment_id"] = AssignmentParticipant.find(id).assignment.id
      session["github_view_type"] = "view_submissions"
      redirect_to :controller => 'metrics', :action => 'authorize_github'
      return
    end

    @head_refs = {} # global reference hash, key is PR number, value is the head commit global id, owner, and repo
    @parsed_data = {} # a hash track each author's commits grouped by date
    @authors = {} # pull request authors
    @dates = {} # dates info for dates that have commits
    @total_additions = 0 # num of lines added
    @total_deletions = 0 # num of lines deleted
    @total_commits = 0 # num of commits in this PR
    @total_files_changed = 0 # num of files changed in this PR
    @merge_status = {} # merge status of this PR open or closed
    @check_statuses = {} # statuses info for each PR

    @token = session["github_access_token"]

    @participant = AssignmentParticipant.find(id)
    @assignment = @participant.assignment # participant has belong_to relationship with assignment
    @team = @participant.team # team method in AssignmentParticipant return the AssignmentTeam of this participant
    @team_id = @team.id

    # retrieve github data and store in the instance variables defined above
    retrieve_github_data

    # get each PR's status info
    query_all_merge_statuses

    #@authors = @authors.keys # only keep the author name info
    @dates = @dates.keys.sort # only keep the date info and sort

    @participants = get_data_for_list_submissions(@team)

    # Create database entry for basic statistics. These data are queried later by view_team in grades (the heatgrid)
    @authors.each do |author|
      # Check to see if this author is a member of the expertiza dev team. This COULD be done with a query,
      # But will only work if the authenticated user running the query has push access to the github repository
      # (Per Github API security rules)
      unless LOCAL_ENV["COLLABORATORS"].include? author[1]
        # If author is a student, keep the commit data and store the total as a Metric
        data_object = {}
        data_object[:author] = author[0] # Github Name
        data_object[:email] = author[1] # Github Email
        data_object[:commits] = @parsed_data[author[0]].values.inject(0) {|sum, value| sum += value} #Sum of commits
        create_github_metric(@team_id, author[1], data_object[:commits])
      end
    end
  end


  ##################### Process Links and Branch according to Pull Request or Repo ############################
  # For a single assignment team, process the submitted links, determine whether they are pull request links or
  # repository links, and branch accordingly to query github for the data from the type of link found. The github API
  # works differently and has different available data for pull requests and repositories.
  def retrieve_github_data
    team_links = @team.hyperlinks # all links that a team submitted
    pull_links = team_links.select do |link|
      link.match(/pull/) && link.match(/github.com/) # all links that contain both pull and github.com
    end
    if !pull_links.empty? # have pull links, retrieve pull request info
      query_all_pull_requests(pull_links)
    else # retrieve repo info if no PR is submitted
    repo_links = team_links.select do |link|
      link.match(/github.com/)
    end
    retrieve_repository_data(repo_links)
    end
  end


  ############### Handling of Pull Request Links #####################

  # Iterate through all pull request links, and initiate the github graphql API queries for each link. Then, call
  # parse_pull_request_data to process the returned data from each link
  def query_all_pull_requests(pull_links)
    pull_links.each do |hyperlink|
      hyperlink_data = parse_hyperlink_data(hyperlink)
      github_data = pull_request_data(hyperlink_data)
  
      # save the global reference id for this pull request
      @head_refs[hyperlink_data["pull_request_number"]] = {
        head_commit: github_data["data"]["repository"]["pullRequest"]["headRefOid"],
        owner: hyperlink_data["owner_name"],
        repository: hyperlink_data["repository_name"]
      }
      parse_pull_request_data(github_data)
    end
  end
  
  # This function pulls data for a pull request from the Github API.
  # It iterates across pages of 100 commits, getting the query from the Metric model,
  # running the query, and then calling the data parser.
  def pull_request_data(hyperlink_data)
    has_next_page = true # Initialize parameter for Github API call
    end_cursor = nil # Initialize parameter needed for Github API call
    all_edges = [] # Initialize an array to store all commits
    response_data = {} # Initialize an empty hash for the response data

    # Loop through all pages of commits
    while has_next_page
      # Make the query message and execute the HTTP request with the query
      # response_data is a Ruby Hash class
      response_data = query_commit_statistics(Metric.pull_query(hyperlink_data, end_cursor))

      # Extract all commits in this pull request and the page info
      current_commits = response_data["data"]["repository"]["pullRequest"]["commits"]
      current_page_info = current_commits["pageInfo"] # Page info for commits in this pull request, because too many commits may spread multiple pages

      # Append each node (i.e., single commit) to all_edges
      # Every element in all_edges is a single commit in the pull request
      all_edges.push(*current_commits["edges"])

      # Get page info for the next page
      has_next_page = current_page_info["hasNextPage"]
      end_cursor = current_page_info["endCursor"]
    end

    # Add every single commit into the response_data hash and return it
    response_data["data"]["repository"]["pullRequest"]["commits"]["edges"] = all_edges
    response_data
  end

  # Parse through data returned from GitHub API, strip unnecessary layers from hashes, and organize data
  # into accessible hash for use elsewhere
  def parse_pull_request_data(github_data)
    team_statistics(github_data, :pull)

    # Get commit objects from pull request object
    commit_objects = github_data.dig("data", "repository", "pullRequest", "commits", "edges")

    # Loop through all commits and do the accounting
    commit_objects.each do |commit_object|
      commit = commit_object.dig("node", "commit")
      author_name = commit.dig("author", "name")
      author_email = commit.dig("author", "email")
      commit_date = commit.dig("committedDate").to_s[0, 10] # Convert datetime object to string in format 2019-04-30

      count_github_authors_and_dates(author_name, author_email, commit_date)
    end

    # Sort author's commits based on dates
    sort_commit_dates
  end


  # iterate through each pull request, and query for the merge and other status information (Merged, rejected, conflicted)
  def query_all_merge_statuses
    @head_refs.each do |pull_number, pr_object|
      @check_statuses[pull_number] = query_pull_request_status(pr_object)
    end
  end


  ####################### Handling of Repository Links #########################
  # Iterate through repository links, and for each link, iterate across pages of 100 commits (API Limit), calling corresponding
  # methods to query the github API  for data on each page, then parse and process the data accordingly.
  def retrieve_repository_data(repo_links)
    has_next_page = true # flag indicating if there are more pages of commits to retrieve
    end_cursor = nil # parameter needed for Github API call
  
    # iterate through each repository link provided
    repo_links.each do |hyperlink|
      # parse the link into its constituent parts
      submission_hyperlink_tokens = hyperlink.split('/')
      hyperlink_data = {}
      # extract repository and owner names from the parsed link and add to the hyperlink_data hash
      hyperlink_data["repository_name"] = submission_hyperlink_tokens[4].gsub('.git', '')
      hyperlink_data["owner_name"] = submission_hyperlink_tokens[3]
  
      # iterate across pages of 100 commits until no more pages are found
      while has_next_page
        # generate query for Github API call using hyperlink_data and other parameters
        query_text = Metric.repo_query(hyperlink_data, @assignment.created_at, end_cursor)
        github_data = query_commit_statistics(query_text)
        # parse repository data only if API did not return an error; otherwise, drop API return hash
        unless github_data.nil? || github_data["errors"] || github_data["data"].nil? || github_data["data"]["repository"].nil? || github_data["data"]["repository"]["ref"].nil?
          parse_repository_data(github_data)
        end
        # only run iteration across an additional page if no API errors and presence of additional pages of commits are detected
        has_next_page = false if github_data.nil? || github_data["data"].nil? || github_data["data"]["repository"].nil? || github_data["data"]["repository"]["ref"].nil? || github_data["errors"] || github_data["data"]["repository"]["ref"]["target"]["history"]["pageInfo"]["hasNextPage"] != "true"
      end
    end
  end

  # Process data returned by a respository query, stripping unecessary layers off of data hash, and organizing data for use
  # elsewhere in the app. Also calls accounting method for each commit, and sorting method to sort the data upon completion.
  # Finally,  calls team_statistics to parse the organized datasets and assemble key instance variables for the views.
  def parse_repository_data(github_data)
    commit_objects = github_data["data"]["repository"]["ref"]["target"]["history"]["edges"]
    commit_objects.each do |commit_object|
      # extract commit author name, email, and date from the commit object and count them using the accounting method
      commit_author = commit_object["node"]["author"]
      author_name = commit_author["name"]
      author_email = commit_author["email"]
      commit_date = commit_author["date"].to_s
      count_github_authors_and_dates(author_name, author_email, commit_date[0, 10])
    end
    # sort commit dates and call team_statistics to process the organized data and assemble instance variables for the views
    sort_commit_dates
    team_statistics(github_data, :repo)
  end

  ####################### Shared Math/Stats and Sorting Methods ################

  # Traverse organized datasets and assemble key instance variables for the views. Handles differences in dataset between
  # pull request queries and repository queries
  def team_statistics(github_data, data_type)
    if data_type == :pull
      if github_data["data"] && github_data["data"]["repository"] && github_data["data"]["repository"]["pullRequest"]
        pull_request = github_data["data"]["repository"]["pullRequest"]
        @total_additions += pull_request["additions"]
        @total_deletions += pull_request["deletions"]
        @total_files_changed += pull_request["changedFiles"]
        @total_commits += pull_request.dig("commits", "totalCount") || 0
        pull_request_number = pull_request["number"]
        @merge_status[pull_request_number] = if pull_request["merged"]
                                               "MERGED"
                                             else
                                               pull_request["mergeable"]
                                             end
      else
        @total_additions = "Not Available"
        @total_deletions = "Not Available"
        @total_files_changed = "Not Available"
        pull_request_number = -1
        @merge_status[pull_request_number] = "Not A Pull Request"
      end
    end
  end  

  # do accounting, aggregate each authors' number of commits on each date
  def count_github_authors_and_dates(author_name, author_email, commit_date)
    return if LOCAL_ENV["COLLABORATORS"].include?(author_name)
  
    @authors[author_name] ||= author_email
    @dates[commit_date] ||= 1
    @parsed_data[author_name] ||= Hash.new(0)
    @parsed_data[author_name][commit_date] += 1
  end

  ######################## HTTP Query Execution #########################

  # make the actual github api request with graphql and query message.
  # data: the query message made in get_query method. Documented in detail in get_query method
  def query_commit_statistics(data)
    uri = URI.parse("https://api.github.com/graphql")
    http = Net::HTTP.new(uri.host, uri.port) # host: api.github.com, port: 443
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    request = Net::HTTP::Post.new(uri.path, 'Authorization' => 'Bearer' + ' ' + session["github_access_token"]) # set up authorization
    request.body = data.to_json # convert query message to json and pass as request body
    response = http.request(request) # make the actual request
    ActiveSupport::JSON.decode(response.body.to_s) # convert the response body to string, decoded then return
  end

  # pr_object contains head commit reference num, author name, and repo name
  # using the github api end point to get the pull request status info
  def query_pull_request_status(pr_object)
    url = "https://api.github.com/repos/" + pr_object[:owner] + "/" + pr_object[:repository] + "/commits/" + pr_object[:head_commit] + "/status"
    ActiveSupport::JSON.decode(Net::HTTP.get(URI(url)))
  end

  # Handle the create action for a github metric, which stores a datapoint mapping a team id, and a github email address
  # to an expertiza User, with a datapoint for their total contributions to the project. Users are asked to create the
  # mapping from their Github email within their user profile, but we also try to intelligently determine that mapping if
  # the user has not provided an email, and their profile contains enough clues.
  def create_github_metric(team_id, github_id, total_commits)
    metric = Metric.where("team_id = ? AND github_id = ?", team_id, github_id).first
    # Attempt to find user by their github email -- Mapping already exists
    user = User.find_by_github_id(github_id) || find_user_by_github_email(github_id)

    participant_id = user&.id

    unless metric.nil?
      metric.total_commits = total_commits
      metric.participant_id = participant_id
      metric.save
    else
      Metric.create(
        metric_source_id: MetricSource.find_by_name("Github").id,
        team_id: team_id,
        github_id: github_id,
        participant_id: participant_id,
        total_commits: total_commits
      )
    end
  end

  def find_user_by_github_email(email)
  email_parts = email.split('@')

  if email_parts[1] == 'ncsu.edu'
    user = User.find_by_email(email)
    user.github_id = email unless user.nil?
    user&.save
  else
    user = User.find_by_email("#{email_parts[0]}@ncsu.edu")
    user.github_id = email unless user.nil?
    user&.save
  end

  user
  end
end