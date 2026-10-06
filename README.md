# UnitXP_SP3 Moonstone

基于 UnitXP_SP3 v89 源码增加“长者的月亮石”风格七色团队光柱。

## 自动编译

仓库内的 GitHub Actions 会自动：

1. 从 Codeberg 拉取 UnitXP_SP3 v89 源码；
2. 校验并应用 Moonstone 光柱补丁；
3. 下载 x86 Windows CRT、Windows SDK 和 D3DX9 头文件；
4. 编译 32 位 `UnitXP_SP3.dll`；
5. 上传 `UnitXP_SP3-Moonstone-x86` 构建产物。

进入仓库顶部 **Actions**，打开 **Build UnitXP_SP3 Moonstone DLL** 即可查看结果。

> 替换 DLL 前请备份原文件。首次版本属于实机测试版，如客户端无法启动，请立即换回旧 DLL。
