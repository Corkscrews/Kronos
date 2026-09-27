Pod::Spec.new do |s|
  s.name = 'Kronos'
  s.version = '4.4.0'
  s.license = { :type => 'Apache License, Version 2.0', :file => 'LICENSE' }
  s.summary = 'Elegant NTP client in Swift'
  s.homepage = 'https://github.com/Corkscrews/Kronos'
  s.authors = { 'Martin Conte Mac Donell' => 'Reflejo@gmail.com', 'Pedro Paulo de Amorim' => 'pp.amorim@hotmail.com' }
  s.source = { :git => 'https://github.com/Corkscrews/Kronos.git', :tag => s.version }
  s.swift_versions = ['5.9']

  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '13.0'
  s.tvos.deployment_target = '13.0'

  s.source_files = 'Sources/*.swift'

  s.resource_bundles = {'Kronos' => ['Sources/PrivacyInfo.xcprivacy']}
end
