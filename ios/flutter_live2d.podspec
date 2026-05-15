Pod::Spec.new do |s|
  s.name             = 'flutter_live2d'
  s.version          = '1.0.2'
  s.summary          = 'Flutter plugin for Live2D Cubism SDK (Native).'
  s.description      = 'Renders Live2D Cubism models inside a Flutter app via OpenGL ES2.'
  s.homepage         = 'https://github.com/linh18nd/flutter_live2d'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'linh18nd' => 'linh18nd@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'

  # All paths are relative to ios/ (where this podspec lives)
  framework_src = 'CubismFramework'
  core_inc      = 'CubismCore/include'
  stb_path      = 'Classes'   # stb_image.h is placed here

  # ---- Source files ----
  plugin_sources    = Dir.glob('Classes/**/*.{h,m,mm,swift}')
  framework_sources = Dir.glob("#{framework_src}/**/*.cpp")

  s.source_files = plugin_sources + framework_sources

  # ---- Resources ----
  # Cubism Framework loads shader sources via the file loader at runtime
  # (see Rendering/OpenGL/CubismShader_OpenGLES2.cpp). They must therefore
  # ship as plain files inside a resource bundle that the plugin can locate
  # at runtime.
  s.resource_bundles = {
    'flutter_live2d' => [
      "#{framework_src}/Rendering/OpenGL/Shaders/StandardES/*.{vert,frag}"
    ]
  }

  # ---- Vendored Core XCFramework (device + simulator) ----
  s.vendored_frameworks = 'Libs/Live2DCubismCore.xcframework'

  # ---- System frameworks ----
  s.frameworks = ['OpenGLES', 'GLKit', 'UIKit', 'Foundation']
  s.libraries  = ['c++', 'z']

  # ---- Build settings ----
  s.pod_target_xcconfig = {
    'DEFINES_MODULE'                        => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]'  => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD'           => 'c++14',
    'CLANG_CXX_LIBRARY'                     => 'libc++',
    'HEADER_SEARCH_PATHS'                   => [
      '$(PODS_TARGET_SRCROOT)/CubismFramework',
      '$(PODS_TARGET_SRCROOT)/CubismCore/include',
      '$(PODS_TARGET_SRCROOT)/Classes',
    ].join(' '),
    'GCC_PREPROCESSOR_DEFINITIONS'          => '$(inherited) CSM_TARGET_IPHONE_ES2=1',
    'OTHER_LDFLAGS'                         => '-ObjC',
  }

  s.dependency 'Flutter'
end
