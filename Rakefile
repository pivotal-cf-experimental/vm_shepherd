require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)

RuboCop::RakeTask.new(:rubocop) do |t|
  t.options << '--lint'
  t.options << '--display-cop-names'
end

task default: [:rubocop, :spec]
