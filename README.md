# VmShepherd [![Build Status](https://travis-ci.org/pivotal-cf-experimental/vm_shepherd.svg)](https://travis-ci.org/pivotal-cf-experimental/vm_shepherd)

Gem for deploying and destroying a VM on different IAASs such as AWS, vSphere, vCloud, and Openstack

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'vm_shepherd'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install vm_shepherd

## Usage

```ruby
require 'vm_shepherd'

settings =  # A Hash with the expected IaaS specific settings.
            # => See YAML under spec/fixtures/shepherd/ for expected values

# create a new VM
shep = VmShepherd::Shepherd.new(settings: settings)
shep.deploy(path: 'path/to/vm.image')

# destroy an existing VM
shep = VmShepherd::Shepherd.new(settings: settings)
shep.destroy
```

## Contributing

1. Fork it ( https://github.com/pivotal-cf-experimental/vm_shepherd/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
