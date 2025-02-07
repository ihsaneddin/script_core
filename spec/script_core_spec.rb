# frozen_string_literal: true

require "msgpack"
require "open3"

RSpec.describe(ScriptCore) do
  it "evaluates a simple script" do
    result = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["stdout", "@stdout_buffer = 'hello'"],
        ["foo", "@output = @input[:result]"]
      ],
      timeout: 1000
    )
    expect(result.errors).to eq([])
    expect(result.success?).to be(true)
    expect(result.output).to eq([26_803_196_617, 0.475])
    expect(result.stdout).to eq("hello")
  end

  it "breaks out of a proc just fine" do
    result = ScriptCore.run(
      input: {},
      sources: [
        ["proc", "[1, 2].each { |i| break }"],
      ],
      timeout: 1000,
    )
    expect(result.errors).to eq([])
    expect(result.success?).to be(true)
  end

  it "round trips binary strings" do
    result = ScriptCore.run(
      input: "hello".encode(Encoding::BINARY),
      sources: [
        ["foo", "@output = @input"]
      ],
      timeout: 1000
    )
    expect(result.success?).to be(true)
    expect(result.output).to eq("hello")
  end

  it "exposes metrics" do
    result = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["stdout", "@stdout_buffer = 'hello'"],
        ["foo", "@output = @input[:result]"]
      ],
      timeout: 1000
    )

    expect(result.measurements.keys).to eq(%i[
                                             in mem init sandbox
                                             decode inject lib compile
                                             eval out
                                           ])
  end

  it "exposes stat" do
    result = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["stdout", "@stdout_buffer = 'hello'"],
        ["foo", "@output = @input[:result]"]
      ],
      timeout: 1000
    )
    expect(result.stat.instructions).to eq(8)
  end

  SCRIPT_SETUP_INSTRUCTION_COUNT = 14
  INSTRUCTION_COUNT_PER_LOOP = 14 # For .times {}

  def expected_instructions(loops)
    SCRIPT_SETUP_INSTRUCTION_COUNT + INSTRUCTION_COUNT_PER_LOOP * loops
  end

  def max_loops(instruction_quota)
    ((instruction_quota - SCRIPT_SETUP_INSTRUCTION_COUNT) / INSTRUCTION_COUNT_PER_LOOP).floor
  end

  it "checks that the instruction quota defaults to 100000 when no limit is given to the ESS" do
    loops = max_loops(100_000)

    result = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["stdout", "#{loops}.times {}"]
      ],
      timeout: 1000
    )

    expect(result.success?).to be(true)
    expect(result.stat.instructions).to be <= expected_instructions(loops)

    result_with_error = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["stdout", "#{loops * 2}.times {}"]
      ],
      timeout: 1000
    )

    expect(result_with_error.success?).to be(false)
    expect(result_with_error.output).to be_nil
    expect(result_with_error.errors).to include(a_kind_of(ScriptCore::EngineInstructionQuotaError))
  end

  it "checks that a given instruction quota is respected" do
    given_quota = rand(1..9_999_999)
    loops = max_loops(given_quota)

    result = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["stdout", "#{loops}.times {}"]
      ],
      timeout: 1000,
      instruction_quota: given_quota
    )

    expect(result.success?).to be(true)
    expect(result.stat.instructions).to be <= expected_instructions(loops)

    result_with_error = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["stdout", "#{loops * 2}.times {}"]
      ],
      timeout: 1000,
      instruction_quota: given_quota
    )

    expect(result_with_error.success?).to be(false)
    expect(result_with_error.output).to be_nil
    expect(result_with_error.errors).to include(a_kind_of(ScriptCore::EngineInstructionQuotaError))
  end

  it "checks that a given instruction quota is respected from a given source index" do
    quota = 15_000
    result = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["ignore", "1000.times {}"], # if we count this one, we'd blow the 15k quota
        ["count", "1000.times {}"]
      ],
      timeout: 1000,
      instruction_quota: quota,
      instruction_quota_start: 1
    )

    expect(result.success?).to be(true)
    expect(result.stat.total_instructions).to be > quota
  end

  it "supports symbols stat" do
    result = ScriptCore.run(
      input: { result: { value: 0.475 } },
      sources: [
        ["stdout", "@stdout_buffer = 'hello'"],
        ["foo", "@output = @input[:result]"]
      ],
      timeout: 1000
    )
    expect(result.output).to eq(value: 0.475)
  end

  it "reports syntax errors" do
    result = ScriptCore.run(
      input: "Yay!",
      sources: [["syntax_error.rb", "end"]],
      timeout: 1
    )
    expect(result.success?).to be(false)
    expect(result.output).to eq(nil)
    expect(result.errors).to have_attributes(length: 1)

    error = result.errors[0]
    expect(error).to be_an(ScriptCore::EngineSyntaxError)
    expect(error.message).to eq("syntax_error.rb:1:3: syntax error, unexpected keyword_end")
    expect(error.filename).to eq("syntax_error.rb")
    expect(error.line_number).to eq(1)
    expect(error.column).to eq(3)
  end

  it "reports raised exception" do
    result = ScriptCore.run(
      input: "Yay!",
      sources: [["raise.rb", <<-SOURCE]],
        def foo
          raise("foo")
        end

        foo
      SOURCE
      timeout: 1
    )
    expect(result.success?).to be(false)
    expect(result.output).to eq(nil)
    expect(result.errors).to have_attributes(length: 1)

    error = result.errors[0]
    expect(error).to be_an(ScriptCore::EngineRuntimeError)
    expect(error.message).to eq("foo")
    expect(error.guest_backtrace).to eq([
                                          "raise.rb:2:in foo",
                                          "raise.rb:5"
                                        ])
  end

  it "reports metrics on raised exception" do
    result = ScriptCore.run(
      input: "Yay!",
      sources: [["foo", 'raise "foobar"']],
      timeout: 1
    )
    expect(result.success?).to be(false)
    expect(result.measurements.keys).to eq(%i[
                                             in mem init sandbox
                                             decode inject lib compile
                                             eval out
                                           ])
  end

  it "reports an engine runtime fatal error on a bad input" do
    result = ScriptCore.run(input: '"Yay!"', sources: "", timeout: 1)
    expect(result.success?).to be(false)
    expect(result.errors).to have_attributes(length: 1)

    error = result.errors[0]
    expect(error).to be_an(ScriptCore::EngineAbnormalExitError)
    expect(error.code).to eq(2)
  end

  it "reports an unknown type error on a bad output" do
    result = ScriptCore.run(input: "Yay!", sources: [["test", "@output = Class"]], timeout: 1)
    expect(result.success?).to be(false)
    expect(result.errors).to have_attributes(length: 1)

    error = result.errors[0]
    expect(error).to be_an(ScriptCore::UnknownTypeError)
  end

  skip "does work with a simple payload" do
    service_path ||= begin
      base_path = Pathname.new(__dir__).parent
      base_path.join("bin/enterprise_script_service").to_s
    end

    Open3.popen3("#{service_path} < tests/data/data.mp") do |_stdin, _stdout, _stderr, thread|
      expect(thread.value.exitstatus).to be(0)
    end
  end

  it "includes the stdout_buffer if it raises" do
    result = ScriptCore.run(
      input: { result: [26_803_196_617, 0.475] },
      sources: [
        ["stdout", "@stdout_buffer = 'hello'"],
        ["foo", "raise \"Ouch!\""]
      ],
      timeout: 1000
    )
    expect(result.success?).to be(false)
    expect(result.output).to eq(nil)
    expect(result.stdout).to eq("hello")
  end
end
