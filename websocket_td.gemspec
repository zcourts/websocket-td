Gem::Specification.new do |s|
  s.name        = 'websocket-td'
  s.version     = File.open('VERSION').first
  s.authors     = ['Courtney Robinson']
  s.email       = ['courtney.robinson@datasift.com']
  s.description = %q{A multi-threaded WebSocket client, i.e. without event machine}
  s.summary     = %q{A client which will offer the option of using green threads or a single threaded evented approach}
  s.homepage    = 'http://github.com/zcourts/websocket-td'
  s.license     = 'BSD'

  s.platform         = Gem::Platform::RUBY
  s.rubygems_version = %q{1.3.6}
  s.required_rubygems_version = Gem::Requirement.new(">= 1.3.6") if s.respond_to? :required_rubygems_version=

  s.add_runtime_dependency('websocket', '~> 1.1.1')
  s.add_development_dependency('rdoc', '> 0')
  s.add_development_dependency('shoulda', '~> 2.11.3')
  s.add_development_dependency('test-unit', '>= 2.5.5')

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.require_paths = ["lib"]
end