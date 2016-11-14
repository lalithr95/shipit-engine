module Shipit
  class Task < ActiveRecord::Base
    PRESENCE_CHECK_TIMEOUT = 15
    ACTIVE_STATUSES = %w(pending running aborting).freeze
    COMPLETED_STATUSES = %w(success error failed flapping aborted).freeze
    UNSUCCESSFUL_STATUSES = %w(error failed aborted flapping).freeze

    attr_accessor :pid

    belongs_to :deploy, foreign_key: :parent_id, required: false # required for fixtures

    belongs_to :user
    belongs_to :stack, touch: true, counter_cache: true
    belongs_to :until_commit, class_name: 'Commit'
    belongs_to :since_commit, class_name: 'Commit'

    has_many :chunks, -> { order(:id) }, class_name: 'OutputChunk', dependent: :delete_all

    serialize :definition, TaskDefinition
    serialize :env, Hash

    scope :success, -> { where(status: 'success') }
    scope :completed, -> { where(status: COMPLETED_STATUSES) }
    scope :active, -> { where(status: ACTIVE_STATUSES) }
    scope :exclusive, -> { where(allow_concurrency: false) }
    scope :unsuccessful, -> { where(status: UNSUCCESSFUL_STATUSES) }

    scope :due_for_rollup, -> { completed.where(rolled_up: false).where('created_at <= ?', 1.hour.ago) }

    after_save :record_status_change
    after_commit :emit_hooks

    class << self
      def durations
        pluck(:started_at, :ended_at).select { |s, e| s && e }.map { |s, e| e - s }
      end
    end

    state_machine :status, initial: :pending do
      before_transition any => :running do |task|
        task.started_at ||= Time.now.utc
      end

      before_transition any => %i(success failed error) do |task|
        task.ended_at ||= Time.now.utc
      end

      after_transition any => %i(success failed error) do |task|
        task.async_refresh_deployed_revision
      end

      after_transition any => :flapping do |task|
        task.update!(confirmations: 0)
      end

      after_transition any => :success do |task|
        task.async_update_estimated_deploy_duration
      end

      event :run do
        transition pending: :running
      end

      event :failure do
        transition %i(running flapping) => :failed
      end

      event :complete do
        transition %i(running flapping) => :success
      end

      event :error do
        transition all => :error
      end

      event :aborting do
        transition all - %i(aborted) => :aborting
      end

      event :aborted do
        transition aborting: :aborted
      end

      event :flap do
        transition %i(failed error success) => :flapping
      end

      state :pending
      state :running
      state :failed
      state :success
      state :error
      state :aborting
      state :aborted
      state :flapping
    end

    def active?
      status.in?(ACTIVE_STATUSES)
    end

    def report_failure!(_error)
      reload
      if aborting?
        aborted!
      else
        failure!
      end
    end

    def report_error!(error)
      write("#{error.class}: #{error.message}\n\t#{error.backtrace.join("\n\t")}\n")
      error!
    end

    delegate :acquire_git_cache_lock, :async_refresh_deployed_revision, :async_update_estimated_deploy_duration,
             to: :stack

    delegate :checklist, to: :definition

    def duration?
      started_at? && ended_at?
    end

    def duration
      Duration.new(ended_at - started_at) if duration?
    end

    def spec
      @spec ||= DeploySpec::FileSystem.new(working_directory, stack.environment)
    end

    def enqueue
      raise "only persisted jobs can be enqueued" unless persisted?
      PerformTaskJob.perform_later(self)
    end

    def write(text)
      chunks.create!(text: text)
    end

    def chunk_output
      if rolled_up?
        output
      else
        chunks.pluck(:text).join
      end
    end

    def schedule_rollup_chunks
      ChunkRollupJob.perform_later(self)
    end

    def rollup_chunks
      ActiveRecord::Base.transaction do
        self.output = chunk_output
        chunks.delete_all
        update_attribute(:rolled_up, true)
      end
    end

    def output
      gzip = self[:gzip_output]

      if gzip.nil? || gzip.empty?
        ''
      else
        ActiveSupport::Gzip.decompress(gzip)
      end
    end

    def output=(string)
      self[:gzip_output] = ActiveSupport::Gzip.compress(string)
    end

    def rollback?
      false
    end

    def rollbackable?
      false
    end

    def supports_rollback?
      false
    end

    def author
      user || AnonymousUser.new
    end

    def finished?
      !pending? && !running? && !aborting?
    end

    def ping
      Shipit.redis.set(status_key, 'alive', ex: PRESENCE_CHECK_TIMEOUT)
    end

    def alive?
      Shipit.redis.get(status_key) == 'alive'
    end

    def report_dead!
      write("ERROR: Background job hasn't reported back in #{PRESENCE_CHECK_TIMEOUT} seconds.")
      error!
    end

    def should_abort?
      @last_abort_count ||= 1
      (@last_abort_count..Shipit.redis.get(abort_key).to_i).each do |count|
        @last_abort_count = count + 1
        yield count
      end
    end

    def request_abort
      Shipit.redis.pipelined do
        Shipit.redis.incr(abort_key)
        Shipit.redis.expire(abort_key, 1.month.to_i)
      end
    end

    def abort!(rollback_once_aborted: false)
      update!(rollback_once_aborted: rollback_once_aborted)

      if alive?
        aborting
        request_abort
      elsif aborting? || aborted?
        aborted
      elsif !finished?
        report_dead!
      end
    end

    def working_directory
      File.join(stack.deploys_path, id.to_s)
    end

    def record_status_change
      @status_changed ||= status_changed?
    end

    def emit_hooks
      return unless @status_changed
      @status_changed = nil
      Hook.emit(hook_event, stack, hook_event => self, status: status, stack: stack)
    end

    def hook_event
      self.class.name.demodulize.underscore.to_sym
    end

    private

    def status_key
      "shipit:task:#{id}"
    end

    def abort_key
      "#{status_key}:aborting"
    end
  end
end
