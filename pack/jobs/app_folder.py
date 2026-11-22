"""独立 App（一 App 一游戏，0.6.4 维护者定）在电脑上的文件：全放这款自己的游戏文件夹（layout.game_dir：games/<英文名>/），删这一个文件夹就删干净这款的电脑产物。

  games/<英文名>/
    <游戏名> v<版本>.ipa      独立 App：「推到 iPhone」写装上的那份（证书签的是签好的，Apple ID 的是未签名容器），「导出」写按签名方式签好或未签名的；
                              出新版本删掉这款旧版本那份，只留一份
    <游戏名>.s2arm            只在「导出」时：这款的资源派生件（同通用壳的游戏包格式，手机导入与壳无关；独立 App 起局只认包内程序，launchctx.c）
    <游戏名>.img              只在「导出」且资源包里有本体 game.img 时：硬链接，同盘不占新空间；建不了硬链接就不放，README 写原位置
    请先读我.txt / README.txt  只留一份：中文界面写「请先读我.txt」，其余界面写 README.txt；正文按界面语言（中 / 英 / 日 / 西 / 法），非英文末尾附英文摘要

不在这个文件夹里、README 点名的：<默认位置>/.programs/<号>（程序备份，删文件夹后「更新 S2Arm」还要用；启动器「删除游戏」连它一起删）。
文件名、README 正文只在这里定（启动器成功页的「下一步」用同一组句子，见 next_steps）。"""
from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

_BAD = re.compile(r'[\\/:*?"<>|\x00-\x1f]')
README = {"zh": "请先读我.txt", "en": "README.txt"}  # 非玩家句（文件名按界面语言）
S2ARM_SUFFIX, IMG_SUFFIX, IPA_SUFFIX = ".s2arm", ".img", ".ipa"


def stem(name, gid):
    """文件名主干：游戏名（玩家在启动器里看到的那个）去掉文件名里不能有的字符；空了用游戏号"""
    return _BAD.sub(" ", name or "").strip().strip(".") or gid.upper()


def ipa_name(name, gid, version):
    v = _BAD.sub(" ", str(version or "")).strip().strip(".")
    return f"{stem(name, gid)} v{v}{IPA_SUFFIX}" if v else f"{stem(name, gid)}{IPA_SUFFIX}"


def old_ipas(folder, name, gid, keep):
    """这款以前写下的独立 App ipa（同主干、「 v」开头或不带版本），keep 除外：出新版本时删掉，只留一份"""
    base = stem(name, gid)
    out = []
    for p in Path(folder).glob("*" + IPA_SUFFIX):
        n = p.name[:-len(IPA_SUFFIX)]
        if p.name != keep and (n == base or n.startswith(base + " v")):
            out.append(p)
    return out


def place_ipa(src, folder, name, gid, version):
    """把 src（ipa）放成 folder/<游戏名> v<版本>.ipa：同盘改名、跨盘复制（临时名 + 改名，写到一半不留半个文件）；删掉这款旧版本的 ipa。→ 新路径"""
    folder = Path(folder)
    out = folder / ipa_name(name, gid, version)
    tmp = folder / f".{out.name}.{os.getpid()}.partial"
    try:
        shutil.copyfile(src, tmp)
        os.replace(tmp, out)
    finally:
        tmp.unlink(missing_ok=True)
    for p in old_ipas(folder, name, gid, out.name):
        p.unlink(missing_ok=True)
    return out


# README 与导出成功页「下一步」的句子（0.6.4：五种语言，按启动器界面语言出；繁中界面用中文那份）。{app} = 游戏名，{ipa} = ipa 文件名，{files} = 要拷进手机的文件，
#   {gid} = 程序号，{where} = 资源本体在游戏库里的原位置。按钮 / 文件夹名同启动器与手机端现有译名（推到 iPhone、续签、删除游戏、放这里导入、重新检查）。非英文的末尾附英文摘要
TEXT = {
    "zh": dict(  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        bullet="· ", join=" 和 ",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        title="{app} — 独立 App（S2Arm 出的「一个 App 一款游戏」）",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_what="【这是什么】",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        what="{ipa} 是这款游戏自己的 iPhone App：主屏上叫「{app}」，图标是这款的，打开直接进游戏。它和通用 S2Arm 互不影响，可以同时装。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_how="【怎么装】（按你用的签名方式看一段）",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        appleId="Apple ID（启动器里登录的）：手机连上电脑，在启动器里点这款的「推到 iPhone」，签名、安装、拷资源一步完成。"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
                "免费 Apple ID 有苹果的限制：同时最多 3 个自己签的 App（AltStore / SideStore 也算），每 7 天最多注册 10 个 App ID，每款独立 App 占一个。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        devCert="开发者证书 / 分发证书：同样可以在启动器里点「推到 iPhone」。只导出时，{ipa} 已经用你的证书签好，用你常用的装 ipa 工具装到证书登记过的设备上。"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
                "用通配（*）描述文件签的开不了「提高内存上限」，大游戏可能内存不够。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        external="AltStore / SideStore：用它们打开 {ipa} 安装（它们用自己的账号签名）。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        imp="只导出、没连手机推的，还要做一步：装好后先打开一次「{app}」，再把这个文件夹里的 {files} 放进 iPhone「文件」App →「我的 iPhone」→「{app}」→「放这里导入」，"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
            "回到「{app}」点「我已放好，重新检查」，它会自动导入。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        elsewhere="  这款的资源本体没能放进这个文件夹（盘不支持硬链接），在：{where}",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_expiry="【到期与续签】",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        expiry="免费 Apple ID 签的 7 天到期，付费开发者账号签的 1 年，证书签的按描述文件的到期日。到期后 App 打不开，手机上的存档还在。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        renew="续签：设备连上电脑，点启动器游戏库最前面的「S2Arm」，在「独立 App」一节点这款的「续签」。AltStore / SideStore 装的，用它们自己的刷新。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_saves="【存档在哪】",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        saves="存档在手机上这个 App 里。启动器每次装、更新、续签这款时，会把手机存档拉一份到这个文件夹的 save_backup/。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_remove="【怎么整体删除】",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        remove1="1. 手机上：长按「{app}」→ 删除 App。手机上这款的存档会一起删掉。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        remove2="2. 电脑上：用启动器删除最干净——游戏库里这款 →「删除游戏」，会连游戏库隐藏文件夹 .programs 里这款的程序备份一起删；"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
                "这个文件夹里有存档备份时，存档会留下，其余全删。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        remove3="   也可以直接删掉这个文件夹：save_backup/ 里的存档备份会一起删掉，想留存档先把它拷走；电脑上还会剩一份程序备份在游戏库的 .programs/{gid}（隐藏文件夹，"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
                "几十 MB），在启动器里点「删除游戏」可以删掉。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
    ),
    "en": dict(
        bullet="- ", join=" and ",
        title="{app} — standalone app (one app, one game, made by S2Arm)",
        h_what="WHAT THIS IS",
        what="{ipa} is this game’s own iPhone app: it shows up as “{app}” on the Home Screen with the game’s icon and opens straight into the game. "
             "It doesn’t affect the S2Arm app; you can have both.",
        h_how="HOW TO INSTALL (read the part for how you sign)",
        appleId="Apple ID (signed in to the launcher): connect the iPhone and click “Push to iPhone” for this game in the launcher. Signing, installing and copying the game data happen in one go. "
                "A free Apple ID is limited by Apple to 3 self-signed apps at a time (AltStore / SideStore count too) and 10 new App IDs every 7 days; each standalone app uses one.",
        devCert="Developer / distribution certificate: “Push to iPhone” in the launcher works too. When you only export, {ipa} is already signed with your certificate; install it on a device registered "
                "in the profile with the ipa installer you usually use. A wildcard (*) profile can’t enable “Increased Memory Limit”, so large games may run out of memory.",
        external="AltStore / SideStore: open {ipa} with them to install it (they sign it with their own account).",
        imp="If you only exported (nothing was pushed from the computer), one more step: after installing, open “{app}” once, then put {files} from this folder into the iPhone Files app → "
            "“On My iPhone” → “{app}” → “Import Here”. Go back to “{app}” and tap “I’ve copied it — check again”; it’s imported automatically.",
        elsewhere="  The game data file couldn’t be placed in this folder (the drive doesn’t support hard links). It is at: {where}",
        h_expiry="EXPIRY AND RENEWING",
        expiry="Apps signed with a free Apple ID expire after 7 days, with a paid developer account after 1 year, and with a certificate on the profile’s expiry date. "
               "An expired app won’t open; the saves on the phone are kept.",
        renew="To renew: connect the device, click “S2Arm” at the top of the launcher’s game library, and click “Renew” for this game in the “Standalone apps” section. If you installed it with AltStore / SideStore, refresh it there.",
        h_saves="WHERE THE SAVES ARE",
        saves="Saves live in this app on the phone. Each time the launcher installs, updates or renews this game, it copies the phone’s saves to save_backup/ in this folder.",
        h_remove="HOW TO REMOVE EVERYTHING",
        remove1="1. On the phone: touch and hold “{app}” → Delete App. The game’s saves on the phone are deleted with it.",
        remove2="2. On the computer: “Delete game” in the launcher is the cleanest. It also deletes this game’s program backup in the library’s hidden .programs folder; "
                "if this folder holds save backups, those are kept and everything else is deleted.",
        remove3="   You can also just delete this folder. The save backups in save_backup/ go with it, so copy them elsewhere first if you want them. A program backup (a few dozen MB) "
                "stays in the library’s hidden folder .programs/{gid}; “Delete game” in the launcher removes it.",
    ),
    "ja": dict(
        bullet="・", join=" と ",
        title="{app} — 単独 App（S2Arm で作った「1 つの App に 1 本のゲーム」）",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_what="【これは何か】",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        what="{ipa} はこのゲーム専用の iPhone App です。ホーム画面では「{app}」と表示され、アイコンもこのゲームのもので、開くとそのままゲームが始まります。S2Arm の App とは別物なので、両方入れておけます。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_how="【インストール方法】（使っている署名方法の項目を読んでください）",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        appleId="Apple ID（ランチャーでサインインしたもの）：iPhone をパソコンにつなぎ、ランチャーでこのゲームの「iPhone に送る」をクリックすると、署名・インストール・データのコピーが一度に終わります。"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
                "無料の Apple ID には Apple の制限があり、自己署名 App は同時に最大 3 個（AltStore / SideStore も数に入ります）、App ID の新規登録は 7 日ごとに最大 10 個までです。単独 App は 1 本につき 1 個使います。",
        devCert="開発者証明書 / 配布証明書：同じくランチャーの「iPhone に送る」が使えます。エクスポートだけの場合、{ipa} はすでにあなたの証明書で署名済みなので、いつも使っている ipa インストールツールで、証明書に登録された端末に入れてください。"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
                "ワイルドカード（*）のプロファイルで署名すると「メモリ上限の引き上げ」を有効にできず、大きなゲームはメモリが足りなくなることがあります。",
        external="AltStore / SideStore：{ipa} をそれらで開いてインストールします（それぞれのアカウントで署名されます）。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        imp="エクスポートだけで、パソコンから送っていない場合はもう一手間あります。インストール後に「{app}」を一度開き、このフォルダの {files} を iPhone の「ファイル」App →「このiPhone内」→「{app}」→「Import Here」に入れ、"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
            "「{app}」に戻って「配置しました — 再確認」をタップすると、自動で取り込まれます。",
        elsewhere="  このゲームのデータ本体はこのフォルダに置けませんでした（ドライブがハードリンク非対応）。場所：{where}",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_expiry="【有効期限と再署名】",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        expiry="無料の Apple ID で署名したものは 7 日、有料の開発者アカウントは 1 年、証明書で署名したものはプロファイルの期限日で切れます。期限が切れると App は開けませんが、iPhone 上のセーブデータは残ります。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        renew="再署名：デバイスをパソコンにつなぎ、ランチャーのゲームライブラリの先頭にある「S2Arm」をクリックして、「単独 App」欄でこのゲームの「再署名」をクリックします。AltStore / SideStore で入れた場合は、それぞれの更新機能を使ってください。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_saves="【セーブデータの場所】",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        saves="セーブデータは iPhone 上のこの App の中にあります。ランチャーでこのゲームをインストール・更新・再署名するたびに、iPhone のセーブデータがこのフォルダの save_backup/ にコピーされます。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        h_remove="【まとめて削除する方法】",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        remove1="1. iPhone：「{app}」を長押し →「App を削除」。iPhone 上のこのゲームのセーブデータも一緒に消えます。",  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
        remove2="2. パソコン：ランチャーで消すのがいちばん確実です。ゲームライブラリでこのゲーム →「ゲームを削除」で、ライブラリの隠しフォルダ .programs にあるこのゲームのプログラムのバックアップも消えます。"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
                "このフォルダにセーブデータのバックアップがある場合はそれだけ残り、ほかはすべて消えます。",
        remove3="   このフォルダを直接削除してもかまいません。save_backup/ のセーブデータのバックアップも一緒に消えるので、残したい場合は先に別の場所へコピーしてください。"  # 非玩家句（README / 下一步按界面语言直接写，各语种同一处）
                "パソコンにはライブラリの隠しフォルダ .programs/{gid} にプログラムのバックアップ（数十 MB）が残ります。ランチャーの「ゲームを削除」で消せます。",
    ),
    "es": dict(
        bullet="- ", join=" y ",
        title="{app} — app independiente (una app, un juego, hecha con S2Arm)",
        h_what="QUÉ ES ESTO",
        what="{ipa} es la app de iPhone propia de este juego: aparece como «{app}» en la pantalla de inicio con el icono del juego y abre directamente el juego. "
             "No afecta a la app S2Arm; puedes tener las dos.",
        h_how="CÓMO INSTALARLA (lee la parte de tu forma de firmar)",
        appleId="Apple ID (con sesión iniciada en el lanzador): conecta el iPhone y haz clic en «Enviar al iPhone» para este juego en el lanzador. La firma, la instalación y la copia de los datos del juego se hacen de una vez. "
                "Un Apple ID gratuito tiene límites de Apple: como máximo 3 apps autofirmadas a la vez (AltStore / SideStore también cuentan) y 10 App ID nuevos cada 7 días; cada app independiente usa uno.",
        devCert="Certificado de desarrollador / de distribución: «Enviar al iPhone» en el lanzador también funciona. Si solo exportas, {ipa} ya está firmada con tu certificado; instálala en un dispositivo registrado "
                "en el perfil con la herramienta de instalación de ipa que uses normalmente. Un perfil comodín (*) no puede activar «Límite de memoria ampliado», así que los juegos grandes pueden quedarse sin memoria.",
        external="AltStore / SideStore: abre {ipa} con ellas para instalarla (la firman con su propia cuenta).",
        imp="Si solo exportaste (no se envió nada desde el ordenador), falta un paso: después de instalarla, abre «{app}» una vez y coloca {files} de esta carpeta en la app Archivos del iPhone → "
            "«En mi iPhone» → «{app}» → «Import Here». Vuelve a «{app}» y toca «Ya lo he copiado, comprobar de nuevo»; se importa automáticamente.",
        elsewhere="  No se pudo poner el archivo de datos del juego en esta carpeta (la unidad no admite enlaces duros). Está en: {where}",
        h_expiry="CADUCIDAD Y RENOVACIÓN",
        expiry="Las apps firmadas con un Apple ID gratuito caducan a los 7 días; con una cuenta de desarrollador de pago, al año; y con un certificado, en la fecha de caducidad del perfil. "
               "Una app caducada no se abre; las partidas guardadas en el teléfono se conservan.",
        renew="Para renovar: conecta el dispositivo, haz clic en «S2Arm» al principio de la biblioteca de juegos del lanzador y luego en «Renovar» para este juego en la sección «Apps independientes». Si la instalaste con AltStore / SideStore, renuévala allí.",
        h_saves="DÓNDE ESTÁN LAS PARTIDAS GUARDADAS",
        saves="Las partidas guardadas están dentro de esta app en el teléfono. Cada vez que el lanzador instala, actualiza o renueva este juego, copia las partidas del teléfono en save_backup/ de esta carpeta.",
        h_remove="CÓMO QUITARLO TODO",
        remove1="1. En el teléfono: mantén pulsada «{app}» → Eliminar app. Las partidas de este juego en el teléfono se eliminan con ella.",
        remove2="2. En el ordenador: «Eliminar juego» en el lanzador es lo más limpio. También elimina la copia del programa de este juego en la carpeta oculta .programs de la biblioteca; "
                "si esta carpeta tiene copias de partidas, esas se conservan y se elimina todo lo demás.",
        remove3="   También puedes eliminar esta carpeta directamente. Las copias de partidas de save_backup/ se van con ella, así que cópialas a otro sitio antes si las quieres. "
                "Queda una copia del programa (unas decenas de MB) en la carpeta oculta .programs/{gid} de la biblioteca; «Eliminar juego» en el lanzador la quita.",
    ),
    "fr": dict(
        bullet="- ", join=" et ",
        title="{app} — app autonome (une app, un jeu, créée avec S2Arm)",
        h_what="DE QUOI S’AGIT-IL",
        what="{ipa} est l’app iPhone propre à ce jeu : elle apparaît sous le nom « {app} » sur l’écran d’accueil avec l’icône du jeu et ouvre directement le jeu. "
             "Elle n’a aucun effet sur l’app S2Arm ; vous pouvez avoir les deux.",
        h_how="COMMENT L’INSTALLER (lisez la partie correspondant à votre façon de signer)",
        appleId="Apple ID (connecté dans le lanceur) : branchez l’iPhone et cliquez sur « Envoyer sur l’iPhone » pour ce jeu dans le lanceur. La signature, l’installation et la copie des données du jeu se font en une fois. "
                "Un Apple ID gratuit est limité par Apple à 3 apps autosignées à la fois (AltStore / SideStore comptent aussi) et 10 nouveaux App ID tous les 7 jours ; chaque app autonome en utilise un.",
        devCert="Certificat de développeur / de distribution : « Envoyer sur l’iPhone » dans le lanceur fonctionne aussi. Si vous exportez seulement, {ipa} est déjà signée avec votre certificat ; installez-la sur un appareil enregistré "
                "dans le profil avec l’outil d’installation d’ipa que vous utilisez d’habitude. Un profil générique (*) ne peut pas activer « Limite de mémoire augmentée », les gros jeux peuvent donc manquer de mémoire.",
        external="AltStore / SideStore : ouvrez {ipa} avec eux pour l’installer (ils la signent avec leur propre compte).",
        imp="Si vous avez seulement exporté (rien n’a été envoyé depuis l’ordinateur), il reste une étape : après l’installation, ouvrez « {app} » une fois, puis placez {files} de ce dossier dans l’app Fichiers de l’iPhone → "
            "« Sur mon iPhone » → « {app} » → « Import Here ». Revenez dans « {app} » et touchez « Je l'ai copié — vérifier à nouveau » ; l’import se fait automatiquement.",
        elsewhere="  Le fichier de données du jeu n’a pas pu être placé dans ce dossier (le disque ne prend pas en charge les liens physiques). Il se trouve ici : {where}",
        h_expiry="EXPIRATION ET RENOUVELLEMENT",
        expiry="Les apps signées avec un Apple ID gratuit expirent au bout de 7 jours, avec un compte développeur payant au bout d’un an, et avec un certificat à la date d’expiration du profil. "
               "Une app expirée ne s’ouvre plus ; les sauvegardes sur le téléphone sont conservées.",
        renew="Pour renouveler : branchez l’appareil, cliquez sur « S2Arm » en tête de la bibliothèque de jeux du lanceur, puis sur « Renouveler » pour ce jeu dans la section « Apps autonomes ». Si vous l’avez installée avec AltStore / SideStore, renouvelez-la depuis ces apps.",
        h_saves="OÙ SONT LES SAUVEGARDES",
        saves="Les sauvegardes sont dans cette app sur le téléphone. À chaque installation, mise à jour ou renouvellement de ce jeu, le lanceur copie les sauvegardes du téléphone dans save_backup/ de ce dossier.",
        h_remove="COMMENT TOUT SUPPRIMER",
        remove1="1. Sur le téléphone : touchez longuement « {app} » → Supprimer l’app. Les sauvegardes de ce jeu sur le téléphone sont supprimées avec elle.",
        remove2="2. Sur l’ordinateur : « Supprimer le jeu » dans le lanceur est le plus propre. Cela supprime aussi la copie du programme de ce jeu dans le dossier caché .programs de la bibliothèque ; "
                "si ce dossier contient des copies de sauvegardes, elles sont conservées et tout le reste est supprimé.",
        remove3="   Vous pouvez aussi supprimer ce dossier directement. Les copies de sauvegardes de save_backup/ partent avec lui : copiez-les ailleurs avant si vous voulez les garder. "
                "Une copie du programme (quelques dizaines de Mo) reste dans le dossier caché .programs/{gid} de la bibliothèque ; « Supprimer le jeu » dans le lanceur la supprime.",
    ),
}
SUMMARY = ("—— English summary ——",
           "{ipa} is this game’s own iPhone app (“{app}” on the Home Screen). Install it by clicking “Push to iPhone” in the S2Arm launcher, or open it with AltStore / SideStore.",
           "If you only exported it, after installing put {files_en} into Files → On My iPhone → {app} → Import Here.",
           "Free Apple ID signatures expire after 7 days; renew from the launcher. Saves live in the app on the phone; deleting the app deletes them.",
           "To remove everything: delete the app on the phone, then use “Delete game” in the launcher (or delete this folder).")


def lang_of(ui):
    """启动器界面语言（zh-Hans / zh-Hant / en / ja / es / fr …）→ README 用哪份：中文（简 / 繁）用中文，日 / 西 / 法各用各的，其余英文"""
    ui = (ui or "zh-Hans").lower()
    return "zh" if ui.startswith("zh") else next((k for k in ("ja", "es", "fr") if ui.startswith(k)), "en")


def _files(lang, s2arm, img):
    names = [n for n in (s2arm, img) if n]
    return TEXT[lang]["join"].join(names)


def next_steps(lang, mode, *, app, ipa, s2arm="", img="", exported=False):
    """成功页「下一步」：只给这次签名方式那一段（mode = appleId / devCert / external），导出时再加导入那一步。→ [句子]
    导出时 Apple ID 模式的 ipa 是未签名的（install.export_app：不连手机签不出能装的包）：先给 AltStore / SideStore 那段，再给连手机推的那段"""
    t = TEXT[lang_of(lang) if lang not in TEXT else lang]
    mode = mode if mode in ("appleId", "devCert", "external") else "external"
    order = ["external", "appleId"] if exported and mode == "appleId" else [mode]
    out = [t[m].format(ipa=ipa, app=app) for m in order]
    if exported:
        out.append(t["imp"].format(app=app, files=_files(lang if lang in TEXT else lang_of(lang), s2arm, img)))
    return out


def readme_text(lang, *, app, ipa, gid, s2arm="", img="", img_elsewhere=""):
    """README 正文（lang = zh / en / ja / es / fr）。非英文的末尾附英文摘要，方便玩家转给别人"""
    lang = lang if lang in TEXT else lang_of(lang)
    t = TEXT[lang]
    s2 = s2arm or f"{stem(app, gid)}{S2ARM_SUFFIX}"
    kw = dict(app=app, ipa=ipa, gid=gid.upper(), files=_files(lang, s2, img), where=img_elsewhere)
    b = t["bullet"]
    body = [t["title"], "", t["h_what"], t["what"], "", t["h_how"],
            b + t["appleId"], b + t["devCert"], b + t["external"], b + t["imp"]]
    if img_elsewhere:
        body.append(t["elsewhere"])
    body += ["", t["h_expiry"], t["expiry"], t["renew"], "", t["h_saves"], t["saves"], "", t["h_remove"], t["remove1"], t["remove2"], t["remove3"]]
    if lang != "en":
        body += [""] + list(SUMMARY)
    kw["files_en"] = _files("en", s2, img)
    return "\n".join(line.format(**kw) for line in body) + "\n"


def write_readme(folder, lang, **kw):
    """写这个文件夹的 README（只留一份：删掉另一种语言那份）。Windows 记事本认 BOM。→ 路径"""
    folder = Path(folder)
    lang = lang if lang in TEXT else lang_of(lang)
    out = folder / README["zh" if lang == "zh" else "en"]
    tmp = folder / f".{out.name}.{os.getpid()}.partial"
    tmp.write_text(readme_text(lang, **kw), encoding="utf-8-sig" if os.name == "nt" else "utf-8")
    os.replace(tmp, out)
    for name in README.values():
        if name != out.name:
            (folder / name).unlink(missing_ok=True)
    return out
