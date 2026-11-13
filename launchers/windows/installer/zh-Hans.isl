; S2Arm 安装程序界面里会出现的系统文字（中文），叠在 Inno Setup 自带的 Default.isl 之上：这里没写的照英文原文。
; 只译本安装 / 卸载流程里真会出现的条目；改动时对照 Inno Setup 同版本的 Default.isl 的键名。

[LangOptions]
LanguageName=简体中文
LanguageID=$0804
LanguageCodePage=0
DialogFontName=Microsoft YaHei UI
DialogFontSize=9
WelcomeFontName=Microsoft YaHei UI
WelcomeFontSize=14

[Messages]
SetupAppTitle=安装
SetupWindowTitle=%1 安装程序
UninstallAppTitle=卸载
UninstallAppFullTitle=卸载 %1
InformationTitle=提示
ConfirmTitle=确认
ErrorTitle=出错了
SetupAlreadyRunning=安装程序已经在运行了。
WindowsVersionNotSupported=S2Arm 需要 64 位的 Windows 10 或 Windows 11。
SetupAppRunningError=S2Arm 正在运行。%n%n请先关掉 S2Arm，再点「确定」继续；点「取消」退出安装。
UninstallAppRunningError=S2Arm 正在运行。%n%n请先关掉 S2Arm，再点「确定」继续；点「取消」退出卸载。
ExitSetupTitle=退出安装
ExitSetupMessage=还没装完。现在退出的话 S2Arm 不会装上，以后可以再运行安装程序。%n%n确定退出吗？
ButtonBack=< 上一步
ButtonNext=下一步 >
ButtonInstall=安装
ButtonOK=确定
ButtonCancel=取消
ButtonYes=是
ButtonYesToAll=全部是
ButtonNo=否
ButtonNoToAll=全部否
ButtonFinish=完成
ButtonBrowse=浏览...
ButtonWizardBrowse=浏览...
WizardSelectDir=安装位置
DiskSpaceGBLabel=至少需要 [gb] GB 可用空间。
DiskSpaceMBLabel=至少需要 [mb] MB 可用空间。
DiskSpaceWarningTitle=磁盘空间不够
DiskSpaceWarning=安装需要至少 %1 KB 可用空间，这个盘只剩 %2 KB。%n%n仍然继续吗？
WizardReady=准备安装
WizardInstalling=正在安装
InstallingLabel=正在把 [name] 装到这台电脑上，请稍候。
FinishedHeadingLabel=装好了
FinishedLabelNoIcons=[name] 已经装到这台电脑上。
FinishedLabel=[name] 已经装到这台电脑上，可以从开始菜单或桌面图标打开。
ClickFinish=点「完成」退出安装程序。
RunEntryExec=现在打开 %1
AbortRetryIgnoreSelectAction=选择怎么处理
AbortRetryIgnoreRetry=再试一次
AbortRetryIgnoreIgnore=跳过这个错误继续
AbortRetryIgnoreCancel=取消安装
StatusExtractFiles=正在写入文件...
StatusCreateIcons=正在创建开始菜单和桌面图标...
StatusCreateRegistryEntries=正在登记卸载信息...
StatusSavingUninstall=正在保存卸载信息...
StatusRollback=正在撤销已做的改动...
ConfirmUninstall=确定要卸载 %1 吗？%n%n只删程序本身；游戏库、存档和出好的 iPhone 包都会保留。
UninstallStatusLabel=正在卸载 %1，请稍候。
UninstalledAll=%1 已卸载。游戏库、存档和出好的 iPhone 包都还在。
UninstalledMost=%1 已卸载。%n%n有几个文件删不掉（可能正被占用），可以以后手动删除。
WizardUninstalling=正在卸载
StatusUninstalling=正在卸载 %1...

; ---- 关程序 / 替换文件出错（11-11 维护者覆盖安装时弹出英文「DeleteFile failed; code 5」）----
WizardPreparing=准备安装
PreparingDesc=正在准备把 [name] 装到这台电脑上。
CannotContinue=安装没法继续，请点「取消」退出。
ApplicationsFound=下面这些程序正在用要更新的文件，建议让安装程序自动关掉它们。
ApplicationsFound2=下面这些程序正在用要更新的文件，建议让安装程序自动关掉它们。装完后安装程序会试着重新打开它们。
CloseApplications=自动关掉这些程序(&A)
DontCloseApplications=不关(&D)
ErrorCloseApplications=没能自动关掉所有程序。请先手动关掉 S2Arm（以及 Impactor），再继续安装。
StatusClosingApplications=正在关掉占用文件的程序……
StatusRestartingApplications=正在重新打开程序……
SetupAborted=安装没有完成。%n%n把问题处理好后再运行一次安装程序。
ErrorFunctionFailedNoCode=%1 没成功
ErrorFunctionFailed=%1 没成功（代码 %2）。多半是这个文件正被别的程序占着：先关掉 S2Arm 和 Impactor，再点「再试一次」。
ErrorFunctionFailedWithMessage=%1 没成功（代码 %2）。%n%3
FileAbortRetryIgnoreSkipNotRecommended=跳过这个文件（不建议）(&S)
FileAbortRetryIgnoreIgnoreNotRecommended=忽略这个错误继续（不建议）(&I)
ErrorReplacingExistingFile=替换已有文件时出错：
ErrorCopying=复制文件时出错：
ErrorCreatingDir=没能创建文件夹「%1」
