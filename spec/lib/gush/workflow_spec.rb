require 'spec_helper'

describe Gush::Workflow do
  subject { TestWorkflow.new("test-workflow") }

  describe "#initialize" do
    context "when configure option is true" do
      it "runs #configure method " do
        expect_any_instance_of(TestWorkflow).to receive(:configure)
        TestWorkflow.new("name", configure: true)
      end
    end
  end

  describe "#stop!" do
    it "marks workflow as stopped" do
      expect{ subject.stop! }.to change{subject.stopped?}.from(false).to(true)
    end
  end

  describe "#start!" do
    it "removes stopped flag" do
      subject.stopped = true
      expect{ subject.start! }.to change{subject.stopped?}.from(true).to(false)
    end
  end

  describe "#to_json" do
    it "returns correct hash" do

      klass = Class.new(Gush::Workflow) do
        def configure
          run FetchFirstJob
          run PersistFirstJob, after: FetchFirstJob
        end
      end

      result = JSON.parse(klass.new("workflow").to_json)
      expected = {
        "id"=>"workflow",
        "name" => klass.to_s,
        "klass" => klass.to_s,
        "status" => "Pending",
        "total" => 2,
        "finished" => 0,
        "started_at" => nil,
        "finished_at" => nil,
        "stopped" => false,
        "logger_builder" => "Gush::LoggerBuilder",
        "nodes" => [
          {
            "name"=>"FetchFirstJob", "klass"=>"FetchFirstJob", "finished"=>false, "enqueued"=>false, "failed"=>false,
            "incoming"=>[], "outgoing"=>["PersistFirstJob"], "finished_at"=>nil, "started_at"=>nil, "failed_at"=>nil,
            "running" => false
          },
          {
            "name"=>"PersistFirstJob", "klass"=>"PersistFirstJob", "finished"=>false, "enqueued"=>false, "failed"=>false,
            "incoming"=>["FetchFirstJob"], "outgoing"=>[], "finished_at"=>nil, "started_at"=>nil, "failed_at"=>nil,
            "running" => false
          }
        ]
      }
      expect(result).to eq(expected)
    end
  end

  describe "#find_job" do
    it "finds job by its name" do
      expect(TestWorkflow.new("test").find_job("PersistFirstJob")).to be_instance_of(PersistFirstJob)
    end
  end

  describe "#run" do
    context "when graph is empty" do
      it "adds new job with the given class as a node" do
        flow = Gush::Workflow.new("workflow")
        flow.run(Gush::Job)
        expect(flow.nodes.first).to be_instance_of(Gush::Job)
      end
    end

    context "when last node is a job" do
      it "attaches job as a child of the last inserted job" do
        tree = Gush::Workflow.new("workflow")
        klass1 = Class.new(Gush::Job)
        klass2 = Class.new(Gush::Job)
        tree.run(klass1)
        tree.run(klass2, after: klass1)
        tree.create_dependencies
        expect(tree.nodes.first).to be_an_instance_of(klass1)
        expect(tree.nodes.first.outgoing.first).to eq(klass2.to_s)
      end
    end
  end

  describe "#logger_builder" do
    it 'sets logger builder for workflow' do
      tree = Gush::Workflow.new("workflow")
      tree.logger_builder(TestLoggerBuilder)
      expect(tree.instance_variable_get(:@logger_builder)).to eq(TestLoggerBuilder)
    end
  end

  describe "#build_logger_for_job" do
    it 'builds a logger' do
      job = double('job')
      allow(job).to receive(:name) { 'a-job' }

      tree = Gush::Workflow.new("workflow")
      tree.logger_builder(TestLoggerBuilder)

      logger = tree.build_logger_for_job(job, :jid)
      expect(logger).to be_a(TestLogger)
      expect(logger.jid).to eq(:jid)
      expect(logger.name).to eq('a-job')
    end
  end

  describe "#failed?" do
    context "when one of the jobs failed" do
      it "returns true" do
        subject.find_job('Prepare').failed = true
        expect(subject.failed?).to be_truthy
      end
    end

    context "when no jobs failed" do
      it "returns true" do
        expect(subject.failed?).to be_falsy
      end
    end
  end

  describe "#running?" do
    context "when no enqueued or running jobs" do
      it "returns false" do
        expect(subject.running?).to be_falsy
      end
    end

    context "when some jobs are enqueued" do
      it "returns true" do
        subject.find_job('Prepare').enqueued = true
        expect(subject.running?).to be_truthy
      end
    end

    context "when some jobs are running" do
      it "returns true" do
        subject.find_job('Prepare').running = true
        expect(subject.running?).to be_truthy
      end
    end
  end

  describe "#finished?" do
    it "returns false if any jobs are unfinished" do
      expect(subject.finished?).to be_falsy
    end

    it "returns true if all jobs are finished" do
      subject.nodes.each {|n| n.finished = true }
      expect(subject.finished?).to be_truthy
    end
  end

  describe "#next_jobs" do
    context "when one of the dependent jobs failed" do
      it "returns only jobs with satisfied dependencies" do
        subject.find_job('Prepare').finished = true
        subject.find_job('FetchFirstJob').failed = true
        expect(subject.next_jobs.map(&:name)).to match_array(["FetchSecondJob"])
      end
    end

    it "returns next non-queued and unfinished jobs" do
      expect(subject.next_jobs.map(&:name)).to match_array(["Prepare"])
    end

    it "returns all parallel non-queued and unfinished jobs" do
      subject.find_job('Prepare').finished = true
      expect(subject.next_jobs.map(&:name)).to match_array(["FetchFirstJob", "FetchSecondJob"])
    end

    it "returns empty array when there are enqueued but unfinished jobs" do
      subject.find_job('Prepare').enqueued = true
      expect(subject.next_jobs).to match_array([])
    end

    it "returns only unfinished and non-queued jobs from a parallel level" do
      subject.find_job('Prepare').finished = true
      subject.find_job('FetchFirstJob').finished = true
      expect(subject.next_jobs.map(&:name)).to match_array(["PersistFirstJob", "FetchSecondJob"])
    end

    it "returns next level of unfished jobs after finished parallel level" do
      subject.find_job('Prepare').finished = true
      subject.find_job('PersistFirstJob').finished = true
      subject.find_job('FetchFirstJob').finished = true
      subject.find_job('FetchSecondJob').finished = true
      expect(subject.next_jobs.map(&:name)).to match_array(["NormalizeJob"])
    end

    context "when mixing parallel tasks with synchronous" do
      it "properly orders nested synchronous flows inside concurrent" do
        flow = Gush::Workflow.new("workflow")

        flow.run Prepare
        flow.run NormalizeJob

        flow.run FetchFirstJob, after: Prepare
        flow.run PersistFirstJob, after: FetchFirstJob, before: NormalizeJob
        flow.run FetchSecondJob, after: Prepare
        flow.run PersistSecondJob, after: FetchSecondJob, before: NormalizeJob

        flow.create_dependencies
        expect(flow.next_jobs.map(&:name)).to match_array(["Prepare"])
        flow.find_job("Prepare").finished = true
        expect(flow.next_jobs.map(&:name)).to match_array(["FetchFirstJob", "FetchSecondJob"])
        flow.find_job("FetchFirstJob").finished = true
        expect(flow.next_jobs.map(&:name)).to match_array(["FetchSecondJob", "PersistFirstJob"])
        flow.find_job("FetchSecondJob").finished = true
        expect(flow.next_jobs.map(&:name)).to match_array(["PersistFirstJob", "PersistSecondJob"])
        flow.find_job("PersistFirstJob").finished = true
        expect(flow.next_jobs.map(&:name)).to match_array(["PersistSecondJob"])
        flow.find_job("PersistSecondJob").finished = true
        expect(flow.next_jobs.map(&:name)).to match_array(["NormalizeJob"])
      end
    end

    it "fails when dependency resolution recurses too deep" do
      flow = Gush::Workflow.new("workflow")
      klass1 = Class.new(Gush::Job)
      klass2 = Class.new(Gush::Job)
      klass3 = Class.new(Gush::Job)
      flow.run(klass1, after: klass3)
      flow.run(klass2, after: klass1)
      flow.run(klass3, after: klass2)
      flow.create_dependencies

      expect {
        flow.next_jobs
      }.to raise_error(Gush::DependencyLevelTooDeep)
    end
  end
end
