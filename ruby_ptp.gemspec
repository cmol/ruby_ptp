# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ruby_ptp/version'

Gem::Specification.new do |spec|
  spec.name          = "ruby_ptp"
  spec.version       = RubyPtp::VERSION
  spec.authors       = ["Claus Lensbøl"]
  spec.email         = ["cmol@cmol.dk"]

  spec.summary       = %q{Ruby implementation of PTP}
  spec.description   = %q{Client implementation of IEEE 1588v2 PTP}
  spec.homepage      = "https://github.com/cmol/ruby_ptp"
  spec.license       = "MIT"

  # Prevent pushing this gem to RubyGems.org by setting 'allowed_push_host', or
  # delete this section to allow pushing this gem to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency 'RubyInline'
  spec.add_runtime_dependency 'slop'

  spec.add_development_dependency "bundler", ">= 2.1.4"
  spec.add_development_dependency "rake", ">= 12.3.3"


end
