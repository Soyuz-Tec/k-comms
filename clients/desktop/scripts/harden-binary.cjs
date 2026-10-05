const path = require('node:path');
module.exports = async context => {
  const { flipFuses, FuseVersion, FuseV1Options } = await import('@electron/fuses');
  const name = context.packager.appInfo.productFilename;
  const binary = context.electronPlatformName === 'darwin'
    ? path.join(context.appOutDir, name + '.app')
    : path.join(context.appOutDir, context.electronPlatformName === 'win32' ? name + '.exe' : context.packager.executableName);
  await flipFuses(binary, { version: FuseVersion.V1,
    resetAdHocDarwinSignature: context.electronPlatformName === 'darwin',
    [FuseV1Options.RunAsNode]: false,
    [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
    [FuseV1Options.EnableNodeCliInspectArguments]: false,
    [FuseV1Options.OnlyLoadAppFromAsar]: true,
    [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: context.electronPlatformName !== 'linux'
  });
};
