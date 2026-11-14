#import "vpad_settings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "s2a_l10n.h"
#include <math.h>

@interface S2AVPadSettings () <UIDocumentPickerDelegate>
@end
@implementation S2AVPadSettings {
    S2AVPadLayoutStore *_store;
    S2AVPadLayout *_current;
    NSArray<S2AVPadLayout *> *_layouts;
    void (^_changed)(void), (^_closed)(void);
    NSURL *_exportDirectory;
    BOOL _importing;
}
- (instancetype)initWithStore:(S2AVPadLayoutStore *)store current:(S2AVPadLayout *)layout
                      changed:(void (^)(void))changed closed:(void (^)(void))closed {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _store = store; _current = layout; _changed = [changed copy]; _closed = [closed copy];
    self.title = store.split ? S2AL(@"vpad.layouts.split.title") : S2AL(@"vpad.layouts.title");
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.embeddedInSettings) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:S2AL(@"common.done") style:UIBarButtonItemStyleDone target:self action:@selector(close)];
        self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"vpad.layouts.done";
    }
    self.navigationController.modalInPresentation = YES;
    if (self.embeddedInSettings) {
        self.tableView.backgroundColor = UIColor.clearColor;
        [self updateMaterial];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateMaterial) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    }
    [self reload];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)updateMaterial {
    BOOL solid = UIAccessibilityIsReduceTransparencyEnabled();
    UIVisualEffectView *material = [[UIVisualEffectView alloc] initWithEffect:solid ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    material.backgroundColor = solid ? UIColor.systemGroupedBackgroundColor : UIColor.clearColor;
    self.tableView.backgroundView = material; [self.tableView reloadData];
}
- (void)reload { _layouts = [_store layouts]; [self.tableView reloadData]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:^{ if (self->_closed) self->_closed(); }]; }
- (void)showError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"vpad.layouts.error") message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.gotIt") style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presented = self.presentedViewController;
    if (presented) [presented dismissViewControllerAnimated:YES completion:^{ [self presentViewController:alert animated:YES completion:nil]; }];
    else [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _store.diagnostics.count ? 5 : 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? _layouts.count + 3 : section == 1 ? 5 : section == 2 ? 5 : section == 3 ? 5 : _store.diagnostics.count;
}
// 0 = 默认布局，1 = 触屏直通，2 = 2D 布局（#268），之后是用户布局（内置三项没有对应文件，所以固定占前三行）
- (NSString *)identifierAtRow:(NSInteger)row {
    if (row == 0) return S2AVPadLayoutDefaultIdentifier;
    if (row == 1) return S2AVPadLayoutTouchIdentifier;
    if (row == 2) return S2AVPadLayout2DIdentifier;
    return _layouts[row - 3].identifier;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? S2AL(@"vpad.layouts.section.choose") : section == 1 ? S2AL(@"vpad.layouts.section.manage") : section == 2 ? S2AL(@"vpad.layouts.section.display") : section == 3 ? S2AL(@"vpad.layouts.section.stick") : S2AL(@"vpad.layouts.section.broken");
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? (_store.split ? S2AL(@"vpad.layouts.split.footer") : S2AL(@"vpad.layouts.footer.choose")) :
        section == 1 ? nil : section == 2 ? S2AL(@"vpad.layouts.footer.display") :
        section == 3 ? S2AL(@"vpad.layouts.footer.stick") :
        S2AL(@"vpad.layouts.footer.broken");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (indexPath.section == 0) {
        NSString *identifier = [self identifierAtRow:indexPath.row];
        S2AVPadLayout *layout = indexPath.row >= 3 ? _layouts[indexPath.row - 3] : nil;
        cell.textLabel.text = layout ? layout.displayName : indexPath.row == 0 ? S2AL(@"vpad.layout.buttons") : indexPath.row == 1 ? S2AL(@"vpad.layout.touch") : S2AL(@"vpad.layout.2d");
        cell.detailTextLabel.text = layout ? layout.identifier : indexPath.row == 0 ?
            S2AL(@"vpad.layouts.buttons.note") : indexPath.row == 1 ? S2AL(@"vpad.layouts.touch.note") : S2AL(@"vpad.layout.2d.note");   // 审计 P1-5：原文「推荐连接手柄时使用」把该选的场景说反了
        cell.accessoryType = [_store.selectedIdentifier isEqualToString:identifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.accessibilityIdentifier = [@"vpad.layout." stringByAppendingString:identifier];
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @[S2AL(@"vpad.layouts.edit"), S2AL(@"vpad.layouts.import"), S2AL(@"vpad.layouts.saveAs"), S2AL(@"vpad.layouts.export"), S2AL(@"vpad.layouts.reset")][indexPath.row];
        cell.accessibilityIdentifier = @[@"vpad.layouts.edit", @"vpad.layouts.import", @"vpad.layouts.save", @"vpad.layouts.export", @"vpad.layouts.reset"][indexPath.row];
        cell.textLabel.textColor = self.view.tintColor;
    } else if (indexPath.section == 2 && indexPath.row == 3) {
        cell.textLabel.text = S2AL(@"vpad.rumble"); cell.detailTextLabel.text = S2AL(@"vpad.layouts.rumble.note"); cell.selectionStyle = UITableViewCellSelectionStyleNone;
        id on = [NSUserDefaults.standardUserDefaults objectForKey:@"S2ARumbleOn"];
        UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = on ? [on boolValue] : YES; toggle.accessibilityIdentifier = @"vpad.rumble.on"; toggle.accessibilityLabel = S2AL(@"vpad.rumble");
        [toggle addTarget:self action:@selector(rumbleSwitch:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
    } else if (indexPath.section == 2 && indexPath.row == 4) {
        id level = [NSUserDefaults.standardUserDefaults objectForKey:@"S2ARumbleLevel"]; NSInteger lv = level ? [level integerValue] : 2;
        cell.textLabel.text = S2AL(@"vpad.rumble.strength"); cell.detailTextLabel.text = @[S2AL(@"vpad.rumble.level.0"), S2AL(@"vpad.rumble.level.1"), S2AL(@"vpad.rumble.level.2"), S2AL(@"vpad.rumble.level.3"), S2AL(@"vpad.rumble.level.4"), S2AL(@"vpad.rumble.level.5")][MAX(0, MIN(5, lv))]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 44)]; slider.minimumValue = 0; slider.maximumValue = 5; slider.value = lv; slider.continuous = NO;
        slider.accessibilityIdentifier = @"vpad.rumble.level"; slider.accessibilityLabel = S2AL(@"vpad.rumble.strength"); [slider addTarget:self action:@selector(rumbleLevel:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = slider;
    } else if (indexPath.section == 2 && indexPath.row == 2) {
        cell.textLabel.text = S2AL(@"vpad.holdLock"); cell.detailTextLabel.text = S2AL(@"vpad.layouts.holdLock.note");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = _store.holdLockEnabled;
        toggle.accessibilityIdentifier = @"vpad.holdLock.enabled"; toggle.accessibilityLabel = S2AL(@"vpad.holdLock");
        [toggle addTarget:self action:@selector(holdLockChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (indexPath.section == 2 && indexPath.row == 1) {
        cell.textLabel.text = S2AL(@"vpad.haptics"); cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = _store.hapticFeedbackEnabled;
        toggle.accessibilityIdentifier = @"vpad.haptics.enabled"; toggle.accessibilityLabel = S2AL(@"vpad.haptics");
        [toggle addTarget:self action:@selector(hapticsChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (indexPath.section == 2) {
        cell.textLabel.text = S2AL(@"vpad.idleOpacity");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", _store.idleKeyOpacity * 100];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 44)];
        slider.minimumValue = 0; slider.maximumValue = 1; slider.value = _store.idleKeyOpacity;
        slider.continuous = NO;   // 手指松开再原子保存一次，不在拖动时反复写盘。
        slider.accessibilityIdentifier = @"vpad.visibility.idleOpacity";
        slider.accessibilityLabel = S2AL(@"vpad.idleOpacity.a11y");
        slider.accessibilityValue = cell.detailTextLabel.text;
        [slider addTarget:self action:@selector(opacityChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider;
    } else if (indexPath.section == 3 && indexPath.row == 3) {
        cell.textLabel.text = S2AL(@"vpad.stick.fixed"); cell.detailTextLabel.text = S2AL(@"vpad.layouts.stickFixed.note"); cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [[UISwitch alloc] init]; toggle.on = _store.stickFixed; toggle.accessibilityIdentifier = @"vpad.stick.fixed"; toggle.accessibilityLabel = S2AL(@"vpad.stick.fixed");
        [toggle addTarget:self action:@selector(stickModeSwitch:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle;
    } else if (indexPath.section == 3 && indexPath.row == 4) {
        cell.textLabel.text = S2AL(@"vpad.stick.sensitivity"); cell.detailTextLabel.text = [NSString stringWithFormat:S2AL(@"vpad.stick.sensValue"), _store.stickSensitivity]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 44)]; slider.minimumValue = 0.5; slider.maximumValue = 2; slider.value = _store.stickSensitivity; slider.continuous = NO;
        slider.accessibilityIdentifier = @"vpad.stick.sensitivity"; slider.accessibilityLabel = S2AL(@"vpad.stick.sensitivity"); [slider addTarget:self action:@selector(stickSensitivityChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = slider;
    } else if (indexPath.section == 3) {
        NSInteger row = indexPath.row;
        CGFloat values[] = {_store.stickDeadzone, _store.stickSaturation, _store.stickExponent};
        float mins[] = {0, .5, .5}, maxs[] = {.4, 1, 3};
        cell.textLabel.text = @[S2AL(@"vpad.stick.deadzone"), S2AL(@"vpad.stick.saturation"), S2AL(@"vpad.stick.exponent")][row];
        cell.detailTextLabel.text = row == 2 ? [NSString stringWithFormat:@"%.2f", values[row]] : [NSString stringWithFormat:@"%.0f%%", values[row] * 100];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 44)];
        slider.minimumValue = mins[row]; slider.maximumValue = maxs[row]; slider.value = values[row]; slider.tag = row; slider.continuous = NO;
        slider.accessibilityLabel = cell.textLabel.text; slider.accessibilityValue = cell.detailTextLabel.text;
        slider.accessibilityIdentifier = @[@"vpad.stick.deadzone", @"vpad.stick.saturation", @"vpad.stick.exponent"][row];
        [slider addTarget:self action:@selector(stickChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = slider; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = _store.diagnostics[indexPath.row]; cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = cell.detailTextLabel.numberOfLines = 0;
    if (self.embeddedInSettings) cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:UIAccessibilityIsReduceTransparencyEnabled() ? 1 : 0.75];
    return cell;
}
- (void)hapticsChanged:(UISwitch *)toggle {
    NSError *error;
    if (![_store setHapticFeedbackEnabled:toggle.on error:&error]) { toggle.on = _store.hapticFeedbackEnabled; [self showError:error]; return; }
    // Feedback is independent of manual layout selection / touch mode.
    [self reload];
}
- (void)holdLockChanged:(UISwitch *)toggle {
    NSError *error;
    if (![_store setHoldLockEnabled:toggle.on error:&error]) { toggle.on = _store.holdLockEnabled; [self showError:error]; return; }
    [self reload];
}
- (void)opacityChanged:(UISlider *)slider {
    NSError *error;
    CGFloat value = roundf(slider.value * 100) / 100;
    if (![_store setIdleKeyOpacity:value error:&error]) { slider.value = _store.idleKeyOpacity; [self showError:error]; return; }
    // Appearance alone must not mark a manual layout choice or change touch mode.
    [self reload];
}
- (void)rumbleSwitch:(UISwitch *)toggle { void s2a_rumble_apply_settings(void), s2a_rumble_preview(void); [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"S2ARumbleOn"]; s2a_rumble_apply_settings(); s2a_rumble_preview(); }
- (void)rumbleLevel:(UISlider *)slider { void s2a_rumble_apply_settings(void), s2a_rumble_preview(void); [NSUserDefaults.standardUserDefaults setInteger:lround(slider.value) forKey:@"S2ARumbleLevel"]; s2a_rumble_apply_settings(); s2a_rumble_preview(); [self reload]; }
- (void)stickModeSwitch:(UISwitch *)toggle {
    NSError *error; if (![_store setStickFixed:toggle.on sensitivity:_store.stickSensitivity error:&error]) { toggle.on = _store.stickFixed; [self showError:error]; return; }
    if (self.stickModeChanged) self.stickModeChanged();
}
- (void)stickSensitivityChanged:(UISlider *)slider {
    NSError *error; if (![_store setStickFixed:_store.stickFixed sensitivity:round(slider.value * 10) / 10 error:&error]) [self showError:error];
    [self reload];
}
- (void)stickChanged:(UISlider *)slider {
    CGFloat values[] = {_store.stickDeadzone, _store.stickSaturation, _store.stickExponent};
    values[slider.tag] = round(slider.value * 100) / 100;
    NSError *error;
    if (![_store setStickDeadzone:values[0] saturation:values[1] exponent:values[2] error:&error]) [self showError:error];
    // 不调用布局选择回调，避免手感设置把“仅触屏”或自动选择状态切成按键模式。
    [self reload];
}
- (BOOL)chooseLayout:(NSString *)identifier {
    NSError *error;
    if (![_store selectIdentifier:identifier error:&error]) { [self showError:error]; return NO; }
    _changed();
    if (self.currentLayout) _current = self.currentLayout();
    else if (![S2AVPadLayout isBuiltinIdentifier:identifier]) _current = [_store selectedLayout:&error];
    // The settings page stays open while the virtual pad regenerates its keys.
    [self reload]; return YES;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self chooseLayout:[self identifierAtRow:indexPath.row]];   // 选完留在本页（11-09 维护者：改设置没有退出意图时不自己退掉），打勾跟着换；关页面用右上角「完成」
    } else if (indexPath.section == 1) {
        switch (indexPath.row) {
            case 0: [self requestEdit]; break;
            case 1: [self importLayout]; break;
            case 2: [self saveCurrent]; break;
            case 3: [self exportCurrent]; break;
            case 4: [self confirmReset]; break;
        }
    }
}
- (void)requestEdit {
    void (^edit)(void) = self.editRequested; void s2a_vpad_set_settings_open(BOOL open);
    [self.navigationController dismissViewControllerAnimated:YES completion:^{ s2a_vpad_set_settings_open(NO); if (edit) edit(); }];
}
- (void)confirmReset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"vpad.layouts.reset.title") message:S2AL(@"vpad.layouts.reset.message") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"vpad.layouts.reset") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self chooseLayout:S2AVPadLayoutDefaultIdentifier];   // 恢复后留在本页（同上）
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)saveCurrent {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:S2AL(@"vpad.layouts.saveAs") message:S2AL(@"vpad.layouts.saveAs.message") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = S2AL(@"vpad.layouts.name"); field.text = [NSString stringWithFormat:S2AL(@"vpad.layouts.copyName"), self->_current.displayName]; field.accessibilityIdentifier = @"vpad.layouts.name"; }];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:S2AL(@"vpad.layouts.save") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSMutableDictionary *doc = [self->_current.document mutableCopy]; doc[@"id"] = NSUUID.UUID.UUIDString.lowercaseString;
        doc[@"name"] = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSError *error; NSData *data = [NSJSONSerialization dataWithJSONObject:doc options:0 error:&error];
        S2AVPadLayout *layout = data ? [S2AVPadLayout readData:data error:&error] : nil;
        if (!layout || ![self->_store saveLayout:layout error:&error]) { [self showError:error]; return; }
        if ([self chooseLayout:layout.identifier]) self->_current = layout;
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)importLayout {
    _importing = YES;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self; picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)cleanExport {
    if (_exportDirectory) [NSFileManager.defaultManager removeItemAtURL:_exportDirectory error:nil];
    _exportDirectory = nil;
}
- (void)exportCurrent {
    [self cleanExport]; _importing = NO;
    _exportDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"s2arm-layout-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtURL:_exportDirectory withIntermediateDirectories:NO attributes:nil error:&error]) { [self showError:error]; return; }
    NSMutableDictionary *document = [_current.document mutableCopy];
    // A built-in export becomes an importable user layout, without claiming the reserved default id.
    if ([S2AVPadLayout isBuiltinIdentifier:_current.identifier]) document[@"id"] = [@"layout-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSURL *url = [_exportDirectory URLByAppendingPathComponent:[document[@"id"] stringByAppendingString:@".json"]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) { [self cleanExport]; [self showError:error]; return; }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url] asCopy:YES];
    picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!_importing) { [self cleanExport]; return; }
    NSURL *url = urls.firstObject; if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error; NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&error];
    NSData *data;
    if ([attributes[NSFileType] isEqualToString:NSFileTypeRegular])
        data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    else if (attributes) error = [NSError errorWithDomain:@"S2Arm.VPadLayout" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:S2AL(@"vpad.layout.error"), @"F01.file", S2AL(@"vpad.layout.err.pickFile")]}];
    if (scoped) [url stopAccessingSecurityScopedResource];
    S2AVPadLayout *layout = data ? [S2AVPadLayout readData:data error:&error] : nil;
    if (!layout || ![_store saveLayout:layout error:&error]) { [self showError:error]; return; }
    if ([self chooseLayout:layout.identifier]) _current = layout;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [self cleanExport]; }
@end
