class Commit < ApplicationRecord
  
  # Git structure
  has_many :branch_memberships, dependent: :destroy
  has_many :branches, through: :branch_memberships
  has_many :parent_relations, class_name: 'CommitRelation',
           foreign_key: :parent_id, dependent: :destroy
  has_many :child_relations, class_name: 'CommitRelation',
           foreign_key: :child_id, dependent: :destroy
  has_many :children, through: :parent_relations
  has_many :parents, through: :child_relations

  # from parsing do1_test_source in tested modules
  has_many :test_case_commits, dependent: :destroy

  # submitted data
  has_many :submissions, dependent: :destroy
  has_many :computers, through: :submissions
  has_many :test_cases, through: :test_case_commits
  has_many :test_instances, through: :test_case_commits

  validates_uniqueness_of :sha, :short_sha
  validates_presence_of :sha, :short_sha, :author, :author_email, :message,
    :commit_time

  after_create :api_update_test_cases

  paginates_per 50


  ####################
  # GITHUB API STUFF #
  ####################
  #
  # NOTE: general stuff in application_record.rb

  # gets all commits from GitHub API and creates or updates them in the
  # database. Does NOT assign branches or test case commits. Those must be
  # done AFTER this
  
  def self.api_commits(**params)
    api.commits(repo_path, **params)
  end

  def self.api_create(sha: nil, **params)
    create_or_update_from_github_hash(
      github_hash: api.commit(repo_path, sha, **params)
    )
  end

  # from a hash, probably generated by an api call, create or update a commit
  # note, this does NOT set parents/children. This is because they are not
  # guaranteed to exist, and this could lead to cyclical api calls as parents
  # of parents of parents are retrieved and created. Instead, you should
  # set up ALL commits first, and then establish relations with one giant
  # call that hits the api only once
  def self.create_or_update_from_github_hash(github_hash: nil, branch: nil)
    commit = if Commit.exists?(sha: github_hash[:sha])
               find_by(sha: github_hash[:sha])
             else
               new(sha: github_hash[:sha])
             end
    commit.update(api_hash_from_github(github_hash))

    # now establish branch membership
    if branch.is_a? Branch
      unless BranchMembership.exists?(branch: branch, commit: commit)
        BranchMembership.create(branch: branch, commit: commit)
      end
    end
    commit
  end

  # gather all commits from GitHub and update database to include and/or
  # update them. Does the following:
  # - Get all commits to some time before the most recent commit (or to the
  #   beginning of time)
  # - Figure out which are missing from database and create them
  # - Set relations for all newly inserted commits
  # - Update branch membership for any newly merged branches
  # Params
  # +branch+ branch to update. +nil+ will update branches and then do them all
  # +force+ if true, gather all commits from api and create them all or update
  #   them if they already exist. Otherwise only gather commits from api from
  #   30 days before the most recent commit, and only create missing commits
  def self.api_update_tree(branch: nil, force: false)
    if branch.nil?
      # make sure we know about every branch
      Branch.api_update_branch_names
      
      # do main method for each branch
      Branch.all.each do |this_branch|
        api_update_tree(branch: this_branch, force: force)
      end

      # Somewhat redundant, as it re-establishes branch names, but also
      # updates head commits and determines whether each branch is merged or
      # not. Crucially, this makes sure that older commits in newly-merged
      # branches have their branch memberships updated
      Branch.api_update_branches
    else
      # Avoid asking api for commits since the beginning of time unless we 
      # REALLY want it.
      github_data = if force || Commit.count.zero?
                      api_commits(sha: branch.name)
                    else
                      api_commits(
                        sha: branch.name,
                        since: 30.days.before(branch.commits.maximum(:commit_time)))
                    end

      # Prevent abusive calls to database to the beginning of time by only
      # looking at new commits in this branch. Note, this allows commits
      # through that already exist in other branches. This is correct, because
      # even if the commit exists, we need to set up a branch membership.
      unless force
        github_shas = github_data.pluck(:sha)
        db_shas = branch.commits.pluck(:sha)

        to_add = github_shas - db_shas
        github_data.select! { |github_hash| to_add.include? github_hash[:sha] }
      end

      Commit.transaction do
        # initialize and/or update commits with basic data and branch
        # memberships, but don't do parent/child relationships yet (relations
        # might not exist, and we get to recursive api hell in a handbasket)
        commits = github_data.map do |github_hash|
          create_or_update_from_github_hash(github_hash: github_hash,
                                            branch: branch)
        end
        # all commits should exist now, so we can safely set up parent/child
        # relations
        github_data.zip(commits).each do |github_hash, commit|
          commit.api_update_parents(github_hash[:parents])
        end

        # still need to update branch ownership if this branch was merged into
        # another (this branch's commits already belong to this branch, but if,
        # for example, this branch was merged into another branch, we don't
        # know that yet). Branch.update_branches (not the basic version) should
        # take care of this in a separate call. If this method is called with
        # no specific branch, you get this automatically. A +force+ call will
        # also handle this, since every single commit gets touched with that.
      end
    end
    nil
  end

  # Update memberships for a branch or all branches. Pairs nicely with update
  # tree, since we can reuse the api payload (which may have been quite
  # expensive) for the commits of a given branch.
  # Params:
  # +branch+: branch to update, +nil+ indicates to update branches and do each
  # +api_payload+: hash containing data from previous api call to comments. If
  #   left +nil+, does the call on its own.
  def self.api_update_memberships(branch: nil, api_payload: nil)
    if branch.nil?
      Branch.api_update_branch_names
      Branch.all.each do |this_branch|
        api_update_memberships(branch: this_branch, api_payload: api_payload)
      end
      Branch.api_update_branches
    else
      api_payload ||= api_commits(sha: branch.name)
      # database ids for all commits in the branch that are in the database
      # Note: does not account for whether all commits are actually present in
      # database
      all_commit_ids = branch.commits.where(sha: api_payload.pluck(:sha)).pluck(:id)

      # database ids for all commits that have a membership in the branch
      existing_commit_ids = BranchMembership.where(branch: branch).pluck(:id)

      # get ids for all commits that don't have the appropriate membership,
      # then batch create the memberships
      needing_membership = all_commit_ids - existing_commit_ids
      BranchMembership.create(
        needing_membership.map do |commit_id|
          {commit_id: commit_id, branch_id: branch.id}
        end)
    end
  end

  def self.api_hash_from_github(github_hash)
    # convert hash from a github api_request representing a commit to 
    # a hash ready to be inserted into the database
    # +github_hash+ a hash for one commit resulting from a github webhook
    # push payload
    {
      sha: github_hash[:sha],
      short_sha: github_hash[:sha][(0...7)],
      author: github_hash[:commit][:author][:name],
      author_email: github_hash[:commit][:author][:email],
      commit_time: github_hash[:commit][:author][:date],
      message: github_hash[:commit][:message],
      github_url: github_hash[:html_url]
    }
  end

  # use github api to query do1_test_source for all modules if it exists
  # and update the test_case_commits for that commit. Only do this for commits
  # with zero test_case_commits
  def self.api_update_test_cases
    Commit.where(test_case_count: 0).each do |commit|
      commit.api_update_test_cases
    end
  end


  ################################################
  # TRANSLATING BETWEEN RAILS AND GITHUB WEBHOOK #
  ################################################

  def self.hash_from_github(github_hash)
    # convert hash from a github webhook payload representing a commit to 
    # a hash ready to be inserted into the database
    # +github_hash+ a hash for one commit resulting from a github webhook
    # push payload

    {
      sha: github_hash[:sha] || github_hash[:id],
      short_sha: (github_hash[:sha] || github_hash[:id])[(0...7)],
      author: github_hash[:author][:name],
      author_email: github_hash[:author][:email],
      commit_time: github_hash[:timestamp],
      message: github_hash[:message],
      github_url: github_hash[:url]
    }
  end

  def self.create_many_from_github_push(payload)
    # take payload from githubs push webhook, extract commits to
    # hashes, and then insert them into the database.
    # 
    # note that the hash structure from webhook is different than api. Should
    # probably name these two silly functions that transform the github hashes
    # into rails-friendly ones...
    create(payload[:commits].map { |commit| hash_from_github(commit) })

    # upon creation, our after_create hook fires and updates test cases and
    # test_case_commits; no need to worry about it here
    
    # update branch memberships for ALL commits, as a merge may have happened
    api_update_memberships
     
    # We do need parent/child relations established. Now all commits exist,
    # do that. We'll also get branches updated for "free" with this expensive
    # API call and database assault. It's not _that_ expensive now, since
    # it will only work on commits made in the last month or so.
    Commit.api_update_tree
  end

  #####################################
  # GENERAL USE AND SEARCHING/SORTING #
  #####################################
  
  def self.parse_sha(sha)
    if sha.downcase == 'head'
      Commit.head
    elsif sha.length == 7
      Commit.find_by(short_sha: sha)
    else
      Commit.find_by(sha: sha)
    end
  end

  # the very first commit. Should have no parents, but in case we've screwed
  # this up, also check for parents (there should be none), and iteratively
  # go through them until there are no more parents
  def self.root
    res = Commit.includes(:parents).order(:commit_time).first
    until res.parents.count.zero?
      res = res.parents.includes(:parents).first
    end
    res
  end

  # get the [Rails] head commit of a particular branch
  # Params:
  # +branch+:: branch for which we want the head node
  def self.head(branch: Branch.master)
    branch.head
  end

  ####################
  # INSTANCE METHODS #
  ####################

  # set parents from api data. Might call api if parents don't exist in
  # database already
  def api_update_parents(parent_hashes)
    # associations
    #
    # first link to parents, if any
    # note, we don't explicitly deal with children relations, since parent
    # relations implicitly take care of it. They would be set whenever this
    # is done to the children
    parent_hashes.each do |parent_hash|
      # if parent doesn't exist, create a dummy withe right sha that will
      # hopefully be filled in later
      new_parent = if Commit.exists?(sha: parent_hash[:sha])
                     Commit.find_by(sha: parent_hash[:sha])
                   else
                     Commit.api_create(sha: parent_hash[:sha])
                   end
      # link the two in a commit relation
      unless CommitRelation.exists?(parent: new_parent, child: self)
        CommitRelation.create(parent: new_parent, child: self)
      end
    end
  end

  # use GitHub api to pull `do1_test_source` for each module and set up
  # test case commits if they don't exist
  def api_test_cases
    cases_present = {}
    TestCase.modules.each do |mod|
      source_file = "/#{mod}/test_suite/do1_test_source"
      begin
        contents = Base64.decode64(
          Commit.api.content(
            Commit.repo_path, path: source_file, query: {ref: sha}).content)
        cases_present[mod] = []
        contents.split("\n").each do |line|
          if /^\s*do_one\s+(\S+)/ =~ line
            cases_present[mod] << $1
          end
        end
      rescue Octokit::NotFound
        puts "No do1_test_source found for module #{mod} in commit #{self}. "\
             "Skipping it."
      end
    end
    cases_present
  end

  def api_update_test_cases
    TestCaseCommit.create_from_commit(self)
    update_scalars
  end

  # get list of commits that are near in +commit_time+ to this commit. If
  # possible, get +limit+ commits, with equal numbers before and after this
  # commit
  def nearby_commits(branch: Branch.master, limit: 11)
    earliest = branch.commits.order(commit_time: :asc).first.commit_time
    before = branch.commits.where(commit_time: earliest...commit_time).
                            order(commit_time: :desc).limit(limit).reverse.to_a
    after = branch.commits.where(commit_time: commit_time..Time.now
    ).where.not(id: id).order(commit_time: :asc).limit(limit).to_a

    # create list of all commits, including this commit
    all_commits = [before, self, after].flatten.sort do |a, b|
      [a.commit_time, a.message] <=> [b.commit_time, b.message]
    end

    # make sure head commit is at the right location
    if all_commits.include? branch.head
      all_commits << all_commits.delete(Commit.head(branch: branch))
    end

    # if its smaller than the limit, we're done
    return all_commits if all_commits.length <= limit

    # find where +self+ is so we can build an array of the right length
    self_index = all_commits.index(self)
    size = all_commits.length
    res = [self]

    i = 0
    while res.length < limit
      one_before = self_index - i - 1
      one_after = self_index + i + 1
      i += 1

      # try to add elements to the front and back of the array, one by one,
      # stopping if we hit an edge
      res.prepend(all_commits[one_before]) if one_before >= 0
      res.append(all_commits[one_after]) if one_after < size
    end
    res.reject(&:nil?)
  end

  def computer_info
    # special call that collects a version's test instances and groups them
    # by unique combinations of computer and computer specificaiton, and
    # ONLY gathers that information
    subs = submissions.select('computer_id, platform_version, sdk_version, '\
      'math_backend, compiler, compiler_version').group(
      'computer_id, platform_version, sdk_version, math_backend, compiler, '\
      'compiler_version')
    specs = []
    subs.each do |sub|
      new_entry = {}
      new_entry[:computer] = Computer.includes(:user).find(sub.computer_id)
      new_entry[:spec] = sub.computer_specification
      new_entry[:numerator] = test_instances.where(
        computer_id: sub.computer_id,
        computer_specification: sub.computer_specification
      ).pluck(:test_case_id).uniq.count
      new_entry[:denominator] = test_cases.count
      new_entry[:frac] = new_entry[:numerator].to_f /
                         new_entry[:denominator].to_f
      compilation_stati = submissions.where(
        computer: new_entry[:computer]
      ).pluck(:compiled).uniq.reject(&:nil?)
      new_entry[:compilation] = case compilation_stati.count
                                when 0
                                  :unknown
                                when 1
                                  compilation_stati[0] ? :success : :failure
                                else
                                  :mixed
                                end
      specs << new_entry

    end
    specs
  end

  # make this stuff searchable directly on the database without having
  # to summon all the test case commits. This should be called whenever
  # a submission is made and whenever a change is made to a test case commit
  def update_scalars
    self.test_case_count = test_case_commits.count
    self.passed_count = test_case_commits.where(status: [0, 2]).count
    self.failed_count = test_case_commits.where(status: 1).count
    self.mixed_count = test_case_commits.where(status: 3).count
    self.checksum_count = test_case_commits.where.not(
      checksum_count: [0, 1]).count
    self.untested_count = test_case_commits.where(status: -1).count
    self.computer_count = computer_info.count
    self.complete_computer_count = computer_info.select do |spec|
      spec[:frac] == 1.0
    end.count
    self.status = if mixed_count > 0
                    3
                  elsif failed_count > 0
                    1
                  elsif checksum_count > 0
                    2
                  elsif passed_count == test_case_count && test_case_count > 0
                    0
                  else
                    -1
                  end
  end

  # 
  # Guide: nil = untested (or unreported)
  #          -1 = no compilation status provided
  #          0  = compiles on all systems so far
  #          1  = fails compilation on all systems so far
  #          2  = mixed results
  # this method just keeps this scheme logically consistent when a new report
  # rolls in, but it DOES NOT save the result to the database.
  def compilation_status
    compile_stati = submissions.pluck(:compiled).reject(&:nil?)
    if compile_stati.empty?
      # no submissions
      return -1
    else
      if compile_stati.uniq.count > 1
        # multiple values; mixed results
        return 2
      else
        if compile_stati[0]
          # first one (and thus all) is true, all passing!
          return 0
        else
          return 1
        end
      end
    end
  end

  def compile_success_count
    submissions.pluck(:compiled).count(true)
  end

  def compile_fail_count
    submissions.pluck(:compiled).count(false)
  end

  # sort commits according to their datetimes, with recent commits FIRST
  def <=>(commit_1, commit_2)
    commit_2.commit_time <=> commit_1.commit_time
  end

  # default string represenation will be the first 7 characters of the SHA
  def to_s
    short_sha
  end

  # first 80 characters of the first line of the message
  # if first line exceeds 80 characters, chop off last word and add an ellipsis
  # remainder will be accessible via +message_rest+
  def message_first_line
    first_line = message.split("\n").first
    return first_line if first_line.length < 80
    first_line.split(' ')[(0...-1)].join(' ')
  end

  # the latter part of the message not captured by +message_first+
  def message_rest
    # if its a short message in one line, we shouldn't have anything left over
    return nil if message_first_line == message

    # determine where rest starts by looking at length of first line, but
    # dropping any ellipsis
    start = message_first_line.chomp('...').length
    res = message[(start..-1)].strip
    return nil if res.empty?
    
    '...' + res.strip
  end
end

class GitError < Exception; end
