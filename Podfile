# FFmpeg 内核播放器（VLC 官方 iOS 封装，内部使用 FFmpeg 解码）
target 'FmHuangguo' do
  use_frameworks!
  pod 'MobileVLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.4'
    end
  end
end
