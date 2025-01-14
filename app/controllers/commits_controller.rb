class CommitsController < ApplicationController
  before_action :set_commit, only: :show

  def show
    @test_case_commits = [@problem_tccs, @skimpy_tccs].flatten.sort_by(&:test_case)

    # populate branch/commit selection menus
    # get all branches that contain this commit, this will be first dropdown
    @selected_branch = Branch.includes(:head).named(CGI.unescape(params[:branch]))
    unless @selected_branch
      # show commit on main if it is there (most likely the old branch was merged into main)
      @selected_branch = Branch.main if @commit.branches.include?(Branch.main)
      
      # didn't find the commit in main? Then just use the first branch we can find.
      @selected_branch ||= @commit.branches.first
      
      # redirect to working path if the specified branch is wrong
      redirect_to(commit_path(sha: @commit.short_sha, branch: @selected_branch.name), alert: "Branch <span class='text-monospace'>#{CGI.unescape(params[:branch])}</span> does not exist. Found commit in <span class='text-monospace'>#{@selected_branch}</span>.") and return
    end
    @other_branches = @commit.branches.reject do |branch|
      branch == @selected_branch
    end.sort_by { |c| c.updated_at }
    @branches = [@selected_branch, @other_branches].flatten

    # Get array of commits made in the same branch around the same time of this
    # commit. For now, get no more than five commits, ideally centered
    # at current commit in time in the branch. That is, if this is the head
    # commit, get ten last commits. If this is the first commit of a branch,
    # get the next ten. If it is in the middle, get five on either side.

    @next_commit, @previous_commit = nil, nil

    @others = @test_case_commits.select { |tcc| !(0..3).include? tcc.status }
    @mixed = @test_case_commits.select { |tcc| tcc.status == 3 }
    @checksums = @test_case_commits.select { |tcc| tcc.status == 2 }
    @failing = @test_case_commits.select { |tcc| tcc.status == 1 }
    @passing = @test_case_commits.select { |tcc| tcc.status == 0 }
    @test_case_commits = [@others, @mixed, @checksums, @failing, @passing].flatten

    @specs = @commit.computer_info
    @statistics = {
      passing: @test_case_commits.select { |tcc| tcc.status.zero? }.count,
      mixed: @test_case_commits.select { |tcc| tcc.status == 3 }.count,
      failing: @test_case_commits.select { |tcc| tcc.status == 1 }.count,
      checksums: @test_case_commits.select { |tcc| tcc.status == 2 }.count,
      other: @test_case_commits.select { |tcc| !(0..3).include? tcc.status }.count
    }

    # giant structure that holds all relevant counts for displaying badges next
    # to test case commits
    @counts = {}
    @failing_instances = {}
    @failure_types = {}
    @checksum_groups = {}
    @test_case_commits.each do |tcc|
      if tcc.checksum_count > 1
        unique_checksums = tcc.unique_checksums
        @checksum_groups[tcc] = {}
        unique_checksums.each do |checksum|
          # more than one checksum? group computers, sorted by name, as values
          # in a hash accessed by their matching checksums
          @checksum_groups[tcc][checksum] = tcc.test_instances.select do |ti|
            ti.checksum == checksum
          end.map { |ti| ti.computer }.uniq.sort_by { |comp| comp.name.downcase }
          # puts '########################################'
          # puts "just assigned checksum #{checksum}"
          # puts '########################################'
        end
      end

      if tcc.failed_count.positive?
        @failing_instances[tcc] = tcc.test_instances.reject(&:passed)
        @failure_types[tcc] = {}
        # create hash that has failure types as keys and arrays of computers,
        # sorted by name, as values
        @failing_instances[tcc].pluck(:failure_type).uniq.each do |failure_type|
          @failure_types[tcc][failure_type] = @failing_instances[tcc].select do |ti|
            ti.failure_type == failure_type
          end.map do |ti| 
            { 
              computer: ti.computer.name,
              run_optional: ti.run_optional,
              fpe_checks: ti.fpe_checks,
              resolution_factor: ti.resolution_factor
            }
          end.uniq.sort_by do |failure_config|
            [failure_config[:run_optional] ? 0 : 1,
             failure_config[:fpe_checks] ? 0 : 1,
             failure_config[:computer]]
          end
        end
      end
      @counts[tcc] = {}
      @counts[tcc][:computers] = tcc.computer_count
      @counts[tcc][:passes] = tcc.passed_count
      @counts[tcc][:failures] = tcc.failed_count
      @counts[tcc][:checksums] = tcc.checksum_count
    end

    @commit_status = case @commit.status
                      when 0 then :passing
                      when 1 then :failing
                      when 2 then :checksum
                      when 3 then :mixed
                      when -1 then :other
                      else
                        :untested
                      end

    @status_text = case @commit_status
                   when :passing then 'All tests passing on all computers.'
                   when :mixed
                     'Some tests fail on some computers and pass on others.'
                   when :failing then 'Some tests fail with all computers.'
                   when :checksum then 'Some tests pass with different ' \
                     'checksums on different computers.'
                   when :other then 'At least some test cases not tested.'
                   else
                     'No tests have been run for this commit.'
                   end

    @status_class = case @commit_status
                    when :passing then 'text-success'
                    when :mixed then 'text-warning'
                    when :failing then 'text-danger'
                    when :checksum then 'text-primary'
                    else
                      'text-info'
                    end
    @compilation_text = case @commit.compilation_status
                        when 0 then 'Successfully compiling on ' +
                                    "#{@commit.compile_success_count} " +
                                    'machines.'
                        when 1 then 'Failing to compile on ' \
                                    "#{@commit.compile_fail_count} machines."
                        when 2 then 'Successfully compiling on ' \
                                    "#{@commit.compile_success_count} and " \
                                    'failing to compile on ' \
                                    "#{@commit.compile_fail_count} machines."
                        else
                          'No compilation information'
                        end

    @compilation_class = case @commit.compilation_status
                         when 0 then 'text-success'
                         when 1 then  'text-danger'
                         when 2 then 'text-warning'
                         else
                           'text-info'
                         end

    # set up colored table rows depending on passage status
    @row_classes = {}
    @last_tested = {}
    @test_case_commits.each do |tcc|
      @last_tested[tcc] = tcc.last_tested
      @row_classes[tcc] =
        case tcc.status
        when 0 then 'table-success'
        when 1 then 'table-danger'
        when 2 then 'table-primary'
        when 3 then 'table-warning'
        else
          'table-info'
        end
    end
  end

  def index
    @page_length = 25
    @branches = Branch.includes(:head).order(:name)
    @branch_names = @branches.pluck(:name)
    @branch = if @branch_names.include? CGI.unescape(params[:branch])
                @branches[@branch_names.index(CGI.unescape(params[:branch]))]
              else
                redirect_to(commits_path(branch: 'main'), alert: "Branch <span class='text-monospace'>#{CGI.unescape(params[:branch])}</span> does not exist; showing commits on <span class='text-monospace'>main</span>.") and return
              end
    # @branch = params[:branch] ? Branch.named(params[:branch]) : Branch.main

    # which page of commits do we want?
    @page = (params[:page] || 1).to_i

    @memberships = @branch.branch_memberships.includes(:commit).where.
                           not(position: nil).order(position: :desc).page(@page)
    @commits = @memberships.map(&:commit)

    # # grab commits for that page (which also includes how many pages there are)
    # commit_shas = Commit.api_commits(
    #   auto_paginate: false,
    #   sha: @branch.head.sha,
    #   per_page: @page_length,
    #   page: @page).map { |c| c[:sha] }
    
    # # determine number of pages through tortured exploration of the "last" link
    # # provided by the api client
    # @num_pages = if Commit.api(auto_paginate: false).last_response.rels[:last]
    #                link = Commit.api(auto_paginate: false).last_response
    #                             .rels[:last].href
    #                m = %r{api.github.com/.*\?page=(?<num_pages>\d+)}.match(link)
    #                m[:num_pages]
    #              else
    #                @page
    #              end.to_i
    
    # # subset = commit_shas[@page_length * (@page - 1), @page_length]
    # @commits = @branch.commits.where(sha: commit_shas).to_a
    #   .sort! { |a, b| commit_shas.index(a.sha) <=> commit_shas.index(b.sha) }      

    @start_num = 1 + (@page - 1) * @memberships.limit_value
    @stop_num = @start_num + @commits.length - 1
    @max_num = @branch.branch_memberships.where.not(position: nil).count

    # @start_num = 1 + (@page - 1) * @page_length
    # @stop_num = @start_num + @commits.length

    # # set buttons for pages
    # @page_button_data = []
    # @page_button_data << if @page > 1
    #                        {
    #                          label: 'First',
    #                          href: commits_path(branch: @branch.name, page: 1),
    #                          klass: '',
    #                          disabled: false
    #                        }
    #                      else
    #                        {
    #                          label: 'First',
    #                          href: '#',
    #                          klass: ' disabled',
    #                          disabled: true
    #                        }
    #                      end
    # 1.upto(@num_pages) do |page|
    #   next unless (page - @page).abs <= 3

    #   @page_button_data << case (page - @page).abs
    #   when 0
    #     {
    #       label: page.to_s,
    #       href: commits_path(branch: @branch.name, page: page),
    #       klass: ' active',
    #       disabled: false
    #     }
    #   when 1..2
    #     {
    #       label: page.to_s,
    #       href: commits_path(branch: @branch.name, page: page),
    #       klass: '',
    #       disabled: false
    #     }
    #   when 3
    #     {
    #       label: '<i class="fa fa-ellipsis-h" aria-hidden="true"></i>'.html_safe,
    #       href: '#',
    #       klass: ' disabled',
    #       disabled: true
    #     }
    #   end

    # end

    # # add "Last" button
    # @page_button_data << if @page < @num_pages
    #                        {
    #                          label: 'Last',
    #                          href: commits_path(branch: @branch.name, page: @num_pages),
    #                          klass: '',
    #                          disabled: false
    #                        }
    #                      else
    #                        {
    #                          label: 'Last',
    #                          href: '#',
    #                          klass: ' disabled',
    #                          disabled: true
    #                        }
    #                      end

    @row_classes = {}
    @btn_classes = {}
    @commits.each do |commit|
      @row_classes[commit] = case commit.status
      when 3 then 'list-group-item-warning'
      when 2 then 'list-group-item-primary'
      when 1 then 'list-group-item-danger'
      when 0 then 'list-group-item-success'
      else
        'list-group-item-info'
      end
      @btn_classes[commit] = case commit.status
      when 3 then 'btn-warning'
      when 2 then 'btn-primary'
      when 1 then 'btn-danger'
      when 0 then 'btn-success'
      else
        'btn-info'
      end

    end
  end

  # API call to allow asynchronous loading of nearby commits
  def nearby_commits
    branch = Branch.includes(:head).named(CGI.unescape(params[:branch]))
    this_commit = Commit.parse_sha(params[:sha])
    commits = branch.nearby_commits(this_commit)

    res = {}
    unless commits.nil? || commits.empty?
      res[:commits] = commits.map do |commit|
        {
          short_sha: commit.short_sha,
          message_first_line: commit.message_first_line(40),
          run_optional: commit.run_optional?,
          fpe_checks: commit.fpe_checks?,
          fine_resolution: commit.fine_resolution?,
          author: commit.author,
          commit_time: format_time(commit.commit_time),
          message_rest: commit.message_rest(40),
          status: commit.status,
          url: commit_url(branch: branch.name, sha: commit.short_sha)
        }
      end
    end

    respond_to do |format|
      format.json do
        render json: res.to_json
      end
    end
  end

  private

  def set_commit
    # @commit = parse_sha(includes: {test_case_commits: [:test_case, {test_instances: [:computer, instance_inlists: :inlist_data]}]})
    @commit = parse_sha(includes: :branches)

    # bail to commits index if the commit doesn't exist
    unless @commit
      redirect_to(commits_path(branch: 'main'), alert: "Could not locate commit <span class='text-monospace'>#{params[:sha]}</span> in any branch. Showing commits in <span class='text-monospace'>main</span>.") and return
    end

    # avoid polling db for tons of instances and instance data if they passed
    # or haven't been tested. Results in an extra call, but avoiding a dragnet
    # of instance data is worth it (I think)
    #
    # First get test cases that are failing, have multiple checksums, or are
    # mixed, for which we will need more information
    @problem_tccs = @commit.test_case_commits.includes(
      :test_case,
      { test_instances: [:computer, { instance_inlists: :inlist_data }] }
    ).where.not(status: -1..0).to_a
    @skimpy_tccs = @commit.test_case_commits.includes(:test_case)
                          .where(status: -1..0).to_a
  end
end
