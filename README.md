# RubyPtp

ruby_ptp is a small daemon implementing the PTPv2 protocol for timing in
networks. Currently running this program will leak memory as all runtime
data is stored for testing porposes. If running this program in a live
setting, these features must be rewritten. The code is higly
experimental as it has been developed as part of a bachelor thesis.
Please think about this before running this program in production!

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ruby_ptp'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install ruby_ptp

## Usage

```bash
usage: ./bin/rubyptp [options]
    -h, --help       print this help message
    -i, --interface  listen interface
    -p, --phc        hardware clock path
    -s, --software   get timestamps using software, else hardware
    -v, --verbose    enable verbose mode
    -q, --quiet      suppress output (quiet mode)
    --version        print the version
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/cmol/ruby_ptp.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

