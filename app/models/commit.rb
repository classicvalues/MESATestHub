class Commit < ApplicationRecord
  has_many :test_case_commits, dependent: :destroy
  has_many :submissions, dependent: :destroy
  
  has_many :test_cases, through: :test_case_commits
  has_many :test_instances, through: :test_case_commits
  has_many :computers, through: :submissions

  validates_uniqueness_of :sha, :short_sha
  validates_presence_of :sha, :short_sha, :author, :author_email, :message,
    :commit_time

  paginates_per 50

  ###########################################
  # WORKING WITH THE NAVIGATING RUGGED TREE #
  ###########################################

  # I hope this is sorting topologically (parents before children), and then by
  # date when there's a tie (merge commits). That might not make sense
  DEFAULT_SORTING = Rugged::SORT_TOPO | Rugged::SORT_DATE

  def self.repo
    # handle into Git repo
    
    # short circuit assignment to avoid re-instantiation
    @repo ||= Rugged::Repository.new(Rails.root.join('public', 'mesa-git'))
    @repo
  end

  def self.fetch
    # update git repo; should be fired every time a push webhook event comes
    # in to the server
    
    credentials = Rugged::Credentials::UserPassword.new(username: 'wmwolf',
      password: ENV['GIT_TOKEN'])
    # strike out my credentials before this goes live!
    repo.fetch('origin', credentials: credentials)
  end

  def self.branches
    # array of names (strings) of branches in repo

    names = repo.branches.map { |branch| branch.name }

    # force 'master' to be first if it exists
    if names.include?('master')
      names.insert(0, names.delete('master'))
    end
    names
  end

  def self.merged_branches(branch=nil)
    if branch.nil?
      branches - unmerged_branches
    else
      check_branch(branch)
      # shell out to get list of branches that are "merged into" the desired
      # branch
      res = `git -C #{repo.path} branch --merged #{branch}`.split("\n")

      # get rid of bogus branch and clear out whitespace
      res.reject! { |branch| branch.include? '(no branch)' }
      res.map!(&:strip)

      # remove branch we are checking against... only want to find OTHER branches
      # that have been merged into this branch
      res.delete(branch)
      res
    end
  end

  # get full SHAs for all commits in a branch by walking through the tree and
  # scooping up commits
  def self.branch_shas(branch = 'master')
    head = rugged_get_head(branch)
  end


  def self.unmerged_branches(branch=nil)
    if branch.nil?
      all = branches
      all_merged = all.inject([]) do |res, branch|
        res + merged_branches(branch)
      end.uniq
      all - all_merged
    else
      check_branch(branch)
      # shell out to get list of branches that are "merged into" the desired
      # branch
      res = `git -C #{repo.path} branch --no-merged #{branch}`.split("\n")

      # get rid of bogus branch and clear out whitespace
      res.reject! { |branch| branch.include? '(no branch)' }
      res.map!(&:strip)

      # remove branch we are checking against... only want to find OTHER branches
      # that have been merged into this branch
      res.delete(branch)
      res
    end
  end

  def self.check_branch(branch)
    unless branches.include? branch
      raise GitError.new(
        "Invalid branch: {#branch}. Must be one of #{branches.join(', ')}."
        )
    end
  end

  def self.head_commit_shas
    # hash mapping branch names to head commits SHA of respective branch

    repo.branches.map { |branch| branch.target.oid }
  end

  def self.rugged_get_branch(branch_name)
    # first branch that matches the name. Problematic for repeated names, but
    # we'll cross that bridge when we get there
    return nil unless branches.include? branch_name
    repo.branches.select { |branch| branch.name == branch_name }.first
  end

  def self.rugged_get_head(branch_name)
    # head commit of a given branch name
    branch = rugged_get_branch(branch_name)
    return nil if branch.nil?
    branch.target
  end

  ########################################
  # TRANSLATING BETWEEN RAILS AND RUGGED #
  ########################################

  def self.hash_from_rugged(commit)
    # convert a rugged commit instance into a has that is ready to be
    # inserted into the database
    # +commit+ a Rugged::Commit instance

    {
      sha: commit.oid,
      short_sha: commit.oid[(0..7)],
      author: commit.author[:name],
      author_email: commit.author[:email],
      commit_time: commit.author[:time],
      message: commit.message
    }
  end

  def self.create_from_rugged(commit)
    # take a rugged commit object and create a database entry
    # +commit+ a Rugged::Commit instance
    new_commit = create(hash_from_rugged(commit))
    TestCaseCommit.create_from_commits([new_commit])
    new_commit.update_scalars
    new_commit.save
  end

  def self.find_from_rugged(commit)
    # given a rugged commit instance, retrieve the database entry
    # +commit+ a Rugged::Commit instance

    find_by_sha(commit.oid)
  end

  def self.sorted_query(shas, includes: nil, page: nil)
    # given a list of sorted shas, find the corresponding commits and return
    # them as a sorted list (in the same order as the shas)
    # 
    # +shas+ list of strings corresponding to commit SHAs
    # +includes+ list of arguments that should go to ActiveRecord query
    query = if includes
              where(sha: shas).order(commit_time: :desc).includes(*includes)
            else
              where(sha: shas).order(commit_time: :desc)
            end
    query.page(page || 1)
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
      sha: github_hash[:id],
      short_sha: github_hash[:id][(0...7)],
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
    commits = create(payload[:commits].map { |commit| hash_from_github(commit) })
    TestCaseCommit.create_from_commits(commits)
    commits.each { |c| c.update_scalars; c.save }
  end

  #####################################
  # GENERAL USE AND SEARCHING/SORTING #
  #####################################
  
  def self.parse_sha(sha, includes: nil)
    if sha.downcase == 'head'
      Commit.head(includes: includes)
    elsif sha.length == 7
      if includes
        Commit.includes(includes).find_by(short_sha: sha)
      else
        Commit.find_by(short_sha: sha)
      end
    else
      if includes
        Commit.includes(includes).find_by(sha: sha)
      else
        Commit.find_by(sha: sha)
      end
    end
  end


  # get the [Rails] head commit of a particular branch
  # Params:
  # +branch+:: branch for which we want the head node
  # +includes+:: argument to be passed on to AcitveRecord#includes (pre-load
  #              associations)
  def self.head(branch: 'master', includes: nil)
    rugged_head = rugged_get_head(branch)
    return nil unless rugged_head
    if includes
      Commit.where(sha: rugged_head.oid).includes(*includes).first
    else
      Commit.where(sha: rugged_head.oid).first
    end
  end

  # get all shas from a particular branch. No guarantee on their order
  # No database queries are done, this just comes from the repo
  def self.shas_in_branch(branch: 'master')
    # Bail if given a bad branch name (and thus no head commit)
    head = rugged_get_head(branch)
    return if head.nil?
    # walk the tree to
    # completion, scraping shas in topological order
    repo.walk(head.oid, DEFAULT_SORTING).map { |commit| commit.oid }
  end

  # ActiveRecord query for all commits in a branch
  #
  # first get list of SHAs for all such commits, then find them in the
  # database. To do this, walk through repo starting at the head node of the
  # branch desired
  # 
  # +branch+ string matching a branch's name. If it isn't found, returns
  # nil
  # +includes+ argument to be passed on to AcitveRecord#includes (pre-load
  # associations)
  def self.all_in_branch(branch: 'master', includes: nil, page: nil)
    sorted_query(shas_in_branch(branch: branch), includes: includes, page: nil)
  end

  def self.subset_of_branch(branch: 'master', size: 25, page: 1,
    includes: nil)
    # Retrieve properly sorted collection of commits, but limit the size
    # 
    # Meant to simulate pagination, but since we have to do sorting on the
    # tree, we can't rely on Rails magic. Instead, we get SHAs of the 
    # relevant commits, find them in the database, and then sort the results
    # accordingly.
    # 
    # +branch+ string matching a branch's name. If it isn't found, returns
    # nil
    # +size+ integer describing the "chunk size" of commits to be returned.
    # Defaults to 25
    # +page+ which chunk to get Essentially we'll start at item (page-1) * size
    # and then scrape the next "size" amount of commits
    # +includes+ argument to be passed on to AcitveRecord#includes (pre-load
    # associations)
    head = rugged_get_head(branch)
    return if head.nil?

    # define parameters for "pagination"
    counter = 0
    start_recording = (page - 1) * size
    stop_recording = page * size
    shas = []
    repo.walk(head, DEFAULT_SORTING).each do |commit|
      # only start recording when we are deep enough, and stop when we are too
      # deep
      shas.append(commit.oid) if counter >= start_recording
      counter += 1
      break if counter >= stop_recording
    end
    sorted_query(shas, includes: includes)
  end

  def self.commits_before(anchor, depth, inclusive: true, includes: nil)
    # retrieve all commits before a certain commit in a branch to some depth
    # 
    # +anchor+ specifies the commit to measure back from (the latest commit),
    # +depth+ is number of commits to go back
    # +inclusive+ is a boolean that determines whether or not to include the
    # anchor commit in the returned list of commits, it does NOT affect the
    # last commit (i.e., setting +depth+ to 100 could produce 100 commits if 
    # +inclusive+ is false, or 101 if it is true)
    # +includes+ argument to be passed on to AcitveRecord#includes (pre-load
    # associations)
    
    counter = 0
    shas = []
    repo.walk(anchor, DEFAULT_SORTING).each do |commit|
      # stop the walk if we've gotten to the desired depth, otherwise
      # add new SHA, increment counter, and keep walking
      break if counter > depth
      shas << commit.oid
      counter += 1
    end
    # get rid of first SHA if we don't want to include the anchor commit
    shas = shas[(1..-1)] unless inclusive
    sorted_query(shas, includes: includes)
  end

  def self.commits_after(anchor, branch, height, inclusive: true,
    includes: nil)
    # retrieve all commits after a certain commit in a branch to some height
    # 
    # +anchor+ specifies the [Rails] commit to measure forward from (the earliest commit),
    # +branch+ valid name of a branch on which to search
    # +height+ is number of commits to go forward
    # +inclusive+ is a boolean that determines whether or not to include the
    # anchor commit in the returned list of commits, it does NOT affect the
    # last commit (i.e., setting +depth+ to 100 could produce 100 commits if 
    # +inclusive+ is false, or 101 if it is true)
    # +includes+ argument to be passed on to AcitveRecord#includes (pre-load
    # associations)
    # 
    # *NOTE* This is harder to do than commits_before because commits only know
    # about their parents rather than their children. We start at the head
    # node of the branch and walk back to the anchor, keeping up to +height+
    # commits
    
    # need head to start down the correct branch. We'll find everything
    # down to `anchor` and then only report the last ones we found
    head = rugged_get_head(branch)
    return nil if head.nil?

    # Take first (only) branch with matching name
    shas = []
    repo.walk(anchor, DEFAULT_SORTING).each do |commit|
      # append commits until we get to desired commit
      shas << commit.oid
      break if commit.oid == anchor.sha
    end

    # trim off later commits, if needed
    shas = shas[-(height+1)..-1] if shas.length > height + 1
    
    # optionally trim off anchor commit as well as excess commits if they exist
    shas.pop unless inclusive

    # now have proper shas. Go get 'em!
    sorted_query(shas, includes: includes)
  end

  # array of test case names being tested in a particular module
  def test_case_names(mod)
    test_suite_dir = File.join(mod, 'test_suite')
    Commit.repo.checkout(sha, options={paths: 
      [File.join(test_suite_dir, 'do1_test_source'),
       File.join(test_suite_dir, 'list_tests')]
    })
    current_dir = Dir.pwd
    full_test_suite_dir = File.join(Commit.repo.path, '..', test_suite_dir)
    return [] unless Dir.exist? full_test_suite_dir
    Dir.chdir(full_test_suite_dir)
    res = `./list_tests`.split("\n").map do |line|
      /^\d+\s+(.+)$/.match(line)[1]
    end
    Dir.chdir(current_dir)
    res
  end

  # list of branch names that contain this commit
  def branches
    res = `git -C #{Commit.repo.path} branch --contains #{sha}`.split("\n")
    res.reject { |line| line =~ /\(no branch\)/}.map(&:strip)
  end

  # get list of commits that are near in +commit_time+ to this commit. If
  # possible, get +limit+ commits, with equal numbers before and after this
  # commit
  def nearby_commits(branch: 'master', limit: 11)
    shas = Commit.shas_in_branch(branch: branch)
    earliest = Commit.where(sha: shas).order(commit_time: :asc).first.commit_time
    before = Commit.where(
      sha: shas,
      commit_time: earliest...commit_time
    ).order(commit_time: :desc).limit(limit).reverse.to_a
    after = Commit.where(
      sha: shas,
      commit_time: commit_time..Time.now
    ).where.not(id: id).order(commit_time: :asc).limit(limit).to_a

    # create list of all commits, including this commit
    all_commits = [before, self, after].flatten.sort do |a, b|
      [a.commit_time, a.message] <=> [b.commit_time, b.message]
    end

    # make sure head commit is at the right location
    if all_commits.include? Commit.head(branch: branch)
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
    res
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
        computer_id: sub.computer_id, computer_specification: sub.computer_specification
      ).pluck(:test_case_id).uniq.count
      new_entry[:denominator] = test_cases.count
      new_entry[:frac] = new_entry[:numerator].to_f / new_entry[:denominator].to_f
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
    # tis = TestInstance.where(commit_id: id)
    #                   .select('computer_id, computer_specification')
    #                   .group('computer_id, computer_specification')
    # # now build an array where each element a hash containing the computer,
    # # the specificaion string, the fraction of test cases from this commit
    # # that have been completed with that computer on that specification,
    # # and whether or not compilation was successful
    # specs = []
    # subs.each do |sub|
    #   new_entry = {}
    #   new_entry[:computer] = Computer.includes(:user).find(ti.computer_id)
    #   new_entry[:spec] = ti.computer_specification
    #   new_entry[:frac] = TestInstance.where(
    #     computer_id: ti.computer_id,
    #     computer_specification: ti.computer_specification
    #   ).pluck(:test_case_id).uniq.count.to_f / test_cases.count.to_f
    #   compilation_stati = submissions.where(
    #     computer: new_entry[:computer]
    #   ).pluck(:compiled).uniq.reject(&:nil?)
    #   new_entry[:compilation] = case compilation_stati.count
    #                             when 0
    #                               :unknown
    #                             when 1
    #                               compilation_stati[0] ? :success : :failure
    #                             else
    #                               :mixed
    #                             end
    #   specs << new_entry
    # end
    #   specs[ti.computer_specification] = 
    #     (specs[ti.computer_specification] || []) + [ti.computer_id]
    # end
    # # convert to Computer objects instead of ids
    # specs.keys.each do |spec|
    #   specs[spec] = Computer.find(specs[spec])
    # end
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
    self.checksum_count = test_case_commits.where.not(checksum_count: [0, 1]).count
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
