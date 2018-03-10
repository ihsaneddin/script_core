ScriptCore
====

ScriptCore is forked by Shopify's enterprise script service.

The enterprise script service (aka ESS) is a thin Ruby API layer that spawns a process, the `enterprise_script_engine`, to execute an untrusted Ruby script.

The `enterprise_script_engine` executable ingests the input from `stdin` as a msgpack encoded payload; then spawns an mruby-engine; uses seccomp to sandbox itself; feeds `library`, `input` and finally the Ruby scripts into the engine; returns the output as a msgpack encoded payload to `stdout` and finally exits.

## Data format

### Input

The input is expected to be a msgpack `MAP` with three keys (Symbol): `library`, `sources`, `input`:

 - `library`: a msgpack `BIN` set of MRuby instructions that will be fed directly to the `mruby-engine`
 - `input`: a msgpack formated payload for the `sources` to digest
 - `sources`: a msgpack `ARRAY` of `ARRAY` with two elements each (tuples): `path`, `source`; the actual code to be executed by the mruby-engine

### Output

The output is msgpack encoded as well; it is streamed to the consuming end though. Streamed items can be of different types.
Each element streamed is in the format of an `ARRAY` of two elements, where the first is a `Symbol` describing the element type:

 * `measurement`: a msgpack `ARRAY` of two elements: a `Symbol` describing the measurement, and an `INT64` with the value in µs.
 * `output`: a msgpack `MAP` with two entries (keys are symbols):
 ** `extracted` with whatever the script put in `@output`, msgpack encoded; and
 ** `stdout` with a `STRING` containing whatever the script printed to "stdout".
 * `stat`: a `MAP` keyed with symbols mapping to their `INT64` values

## Errors

When the ESS fails to serve a request, it communicates the error back to the caller by returning a non-zero status code.
It can also report data about the error, in certain cases, over the pipe. In does so in returning a tuple, as an `ARRAY` with the type being the symbol `error` and the payload being a `MAP`. The content of the map will vary, but it always will have a `__type` symbol key that defines the other keys.

## Build

Run `./bin/rake` to build the project. This effectively runs the `spec` target, which builds all libraries, the ESS and native tests; then runs all tests (native and Ruby).

To rebuild the entire project (which is useful when switching from one OS to another), use `./bin/rake mrproper`.

## Using it

The sample script `bin/sandbox` reads Ruby input from a file or stdin, executes it, and displays the results.

You can invoke ESS from your own Ruby code as follows:

```ruby
result = ScriptCore.run(
  input: {result: [26803196617, 0.475]}, # <1>
  sources: [
    ["stdout", "@stdout_buffer = 'hello'"],
    ["foo", "@output = @input[:result]"], # <2>
  ],
  instructions: nil, # <3>
  timeout: 10.0, # <4>
  instruction_quota: 100000, # <5>
  instruction_quota_start: 1, # <6>
  memory_quota: 8 << 20  # <7>
)
expect(result.success?).to be(true)
expect(result.output).to eq([26803196617, 0.475])
expect(result.stdout).to eq("hello")
```

- <1> invokes the ESS, with a map as the `input` (available as `@input` in the sources)
- <2> two "scripts" to be executed, one sets the `@stdout_buffer` to a value, the second returns the value associated with the key `:result` of the map passed in in <1>
- <3> some raw instructions that will be fed directly into MRuby; defaults to nil
- <4> a 10 second time quota to spawn, init, inject, eval and finally output the result back; defaults to 1 second
- <5> a 100k instruction limit that that the engine will execute; defaults to 100k
- <6> starts counting the instructions at index 1 of the `sources` array
- <7> creates an 8 megabyte memory pool in which the script will run

## Where are things?

### C++ sources

Consists of our code base, plus `seccomp` and `msgpack` libraries, as well as the `mruby` stuff. All in `ext/enterprise_script_service`

Note: lib `seccomp` is omitted on Darwin.

### Ruby layer

Ruby code is in `lib/`

### Tests

- GoogleTest tests are in `tests/`, which also includes the Google Test library.
- RSpec tests are in `spec/`

## Other useful things

- There is a `CMakeLists.txt` that's mainly there for CLion support; we don't use cmake to build any of this.
- You can use vagrant to bootstrap a VM to test under Linux while on Darwin; this is useful when testing `seccomp`.

### Clone git submodules

`git submodule update --init --recursive`

### Vagrant

```
$ vagrant up
$ vagrant ssh
vagrant@vagrant-ubuntu-trusty-64:~$ cd /vagrant
vagrant@vagrant-ubuntu-trusty-64:/vagrant$ bundle install
vagrant@vagrant-ubuntu-trusty-64:/vagrant$ git submodule init
vagrant@vagrant-ubuntu-trusty-64:/vagrant$ git submodule update
vagrant@vagrant-ubuntu-trusty-64:/vagrant$ bin/rake
```

## Contributing

Bug report or pull request are welcome.

### Make a pull request

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

Please write unit test with your code if necessary.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
