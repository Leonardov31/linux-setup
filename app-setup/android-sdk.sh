#!/usr/bin/env zsh

echo 'Downloading android-sdk'
wget https://dl.google.com/android/repository/commandlinetools-linux-6858069_latest.zip

echo 'Directory for android-sdk'
mkdir ~/.dev/android-sdk

echo 'Extracting file'
unzip commandlinetools-linux-6858069_latest.zip -d ~/.dev/android-sdk  

echo 'Moving package to expect location'
mv ~/.dev/android-sdk/cmdline-tools ~/.dev/android-sdk/latest
mkdir ~/.dev/android-sdk/cmdline-tools/
mv ~/.dev/android-sdk/latest ~/.dev/android-sdk/cmdline-tools/

echo 'Removing downloaded file'
rm commandlinetools-linux-6858069_latest.zip

echo 'Adding android-sdk to path'
echo 'export PATH=$HOME/.dev/android-sdk/cmdline-tools/latest/bin:$PATH' >> ~/.zshrc
echo 'export PATH=$HOME/.dev/android-sdk/platform-tools:$PATH' >> ~/.zshrc

source ~/.zshrc

sdkmanager "build-tools;30.0.2" "platforms;android-30"