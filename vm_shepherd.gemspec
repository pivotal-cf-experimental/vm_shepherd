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

  spec.add_dependency 'ruby_vcloud_sdk', '0.7.2'

  spec.add_dependency 'rbvmomi'

  spec.add_development_dependency 'bundler', '~> 1.9'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 3.2'
  spec.add_development_dependency 'recursive-open-struct', '~> 0.5.0'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'codeclimate-test-reporter'
end
