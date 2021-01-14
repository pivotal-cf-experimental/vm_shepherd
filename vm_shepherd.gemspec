# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'vm_shepherd/version'

Gem::Specification.new do |spec|
  spec.name        = 'vm_shepherd'
  spec.version     = VmShepherd::VERSION
  spec.authors     = ['Ops Manager Team']
  spec.email       = ['cf-tempest-eng@pivotal.io']
  spec.summary     = %q{A tool for booting and tearing down Ops Manager VMs on various Infrastructures.}
  spec.description = %q{A tool for booting and tearing down Ops Manager VMs on various Infrastructures.}
  spec.homepage    = ''

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_dependency 'aws-sdk-v1'
  spec.add_dependency 'fog', '1.34.0'
  spec.add_dependency 'net-ssh', '4.2.0' # because fog uses this but doesn't require it

  spec.add_dependency 'ruby_vcloud_sdk', '0.7.4'

  spec.add_dependency 'rbvmomi', '1.11.3'
  spec.add_dependency 'xmlrpc'

  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'rubocop'
end
