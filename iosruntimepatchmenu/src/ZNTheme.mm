#import "ZNTheme.h"

static UIColor *ZNHexColor(uint32_t rgb, CGFloat alpha) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:alpha];
}

typedef struct {
    BOOL light;
    BOOL neon;
    BOOL mechanical;
    ZNThemeDecorationStyle decoration;
    uint32_t panel, header, sidebar, card, control;
    uint32_t primary, secondary, accent, accent2, border, track, floating, shadow;
} ZNThemeSpec;

@interface ZNTheme ()
@property(nonatomic, assign, readwrite) ZNThemeMode mode;
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, assign, readwrite) BOOL lightAppearance;
@property(nonatomic, assign, readwrite) BOOL neonAppearance;
@property(nonatomic, assign, readwrite) BOOL mechanicalAppearance;
@property(nonatomic, assign, readwrite) ZNThemeDecorationStyle decorationStyle;
@property(nonatomic, strong, readwrite) UIColor *panelColor;
@property(nonatomic, strong, readwrite) UIColor *headerColor;
@property(nonatomic, strong, readwrite) UIColor *sidebarColor;
@property(nonatomic, strong, readwrite) UIColor *cardColor;
@property(nonatomic, strong, readwrite) UIColor *popoverColor;
@property(nonatomic, strong, readwrite) UIColor *controlColor;
@property(nonatomic, strong, readwrite) UIColor *footerColor;
@property(nonatomic, strong, readwrite) UIColor *primaryTextColor;
@property(nonatomic, strong, readwrite) UIColor *secondaryTextColor;
@property(nonatomic, strong, readwrite) UIColor *accentColor;
@property(nonatomic, strong, readwrite) UIColor *accent2Color;
@property(nonatomic, strong, readwrite) UIColor *separatorColor;
@property(nonatomic, strong, readwrite) UIColor *borderColor;
@property(nonatomic, strong, readwrite) UIColor *selectedColor;
@property(nonatomic, strong, readwrite) UIColor *trackColor;
@property(nonatomic, strong, readwrite) UIColor *floatColor;
@property(nonatomic, strong, readwrite) UIColor *shadowColor;
@end

@implementation ZNTheme

+ (NSArray<NSString *> *)themeNames {
    return @[
        @"跟随系统", @"曜石暗夜", @"霓虹赛博", @"冰川蓝图", @"琥珀机械", @"抹茶极简",
        @"玻璃拟态", @"终端黑客", @"羊皮卷复古", @"和风木质", @"医疗仪表盘", @"太空舰桥",
        @"蒸汽工坊", @"哥特秘仪", @"糖果潮玩", @"纸墨国风", @"极地军械", @"熔岩锻造",
        @"深海声呐", @"复古街机"
    ];
}

+ (NSString *)nameForMode:(ZNThemeMode)mode {
    NSArray<NSString *> *names = [self themeNames];
    NSInteger idx = MAX(0, MIN((NSInteger)names.count - 1, (NSInteger)mode));
    return names[idx];
}

+ (ZNThemeSpec)specForMode:(ZNThemeMode)mode {
    switch (mode) {
        case ZNThemeModeObsidian:      return {NO,NO,NO,ZNThemeDecorationObsidian,   0x11151B,0x171B21,0x14181E,0x20262E,0x2B323C,0xF2F4F7,0x9DA6B3,0x4D8DFF,0x79A8FF,0x8792A3,0x434A54,0x151A22,0x000000};
        case ZNThemeModeNeon:          return {NO,YES,NO,ZNThemeDecorationNeonCircuit,0x080D1E,0x0D1530,0x091126,0x111B36,0x182345,0xF5F6FF,0x94ACDF,0xD12DFF,0x21D8FF,0x3D7FFF,0x5268A5,0x0B1020,0x8D22FF};
        case ZNThemeModeGlacier:       return {YES,NO,NO,ZNThemeDecorationBlueprint,0xEAF4FF,0xE3F0FF,0xE7F2FF,0xFFFFFF,0xE4EFFB,0x0A356F,0x4C6F9F,0x3389F7,0x30C2F4,0x7BA9DD,0xA9C6E7,0x1E4C91,0x498FD6};
        case ZNThemeModeAmber:         return {NO,NO,YES,ZNThemeDecorationMechanical,0x15120E,0x1B1711,0x18140F,0x242019,0x30291E,0xFFF5E2,0xC8B89D,0xFFB52B,0xD88312,0xC98222,0x6C5B42,0x1B160F,0xFF9C16};
        case ZNThemeModeMatcha:        return {YES,NO,NO,ZNThemeDecorationMatcha,    0xF6F8F3,0xF8FAF6,0xF0F5ED,0xFFFFFF,0xEDF4EA,0x153A2B,0x617569,0x43B95D,0x2D7B48,0x8FB29A,0xC7D9CA,0x285D3C,0x5E8F6C};
        case ZNThemeModeGlass:         return {YES,NO,NO,ZNThemeDecorationGlass,     0xDCE9F7,0xECF4FC,0xD8E6F4,0xF5FAFF,0xE7F0FA,0x17354F,0x58748D,0x56B9FF,0xA686FF,0xAFCBE5,0xBCD0E2,0x397EAB,0x65A7D6};
        case ZNThemeModeTerminal:      return {NO,YES,NO,ZNThemeDecorationTerminal,  0x030805,0x06110A,0x040C07,0x07130B,0x0A1B10,0x66FF99,0x35C86B,0x3CFF83,0xA0FFBE,0x28A95A,0x164A2A,0x06150B,0x28FF73};
        case ZNThemeModeParchment:     return {YES,NO,NO,ZNThemeDecorationParchment, 0xE7D0A4,0xD9B980,0x6B4125,0xF0DDB5,0xD5B37B,0x402514,0x775333,0x1B69C9,0x8C5D2C,0x8C653B,0xB7996C,0x684027,0x4A2C18};
        case ZNThemeModeWashiWood:     return {YES,NO,NO,ZNThemeDecorationWood,      0xE9D8B9,0xDCC9A7,0x744B2E,0xF3E5CA,0xCFB48D,0x39291C,0x745B43,0xB15D35,0x6E8B5D,0x9B744C,0xC9B28C,0x6C452A,0x55321D};
        case ZNThemeModeMedical:       return {YES,NO,NO,ZNThemeDecorationMedical,   0xEFF9FB,0xF8FDFE,0xEAF5F7,0xFFFFFF,0xEAF7F8,0x073B4C,0x54808B,0x13BFC3,0x37D9CE,0x8BCDD2,0xC1DDE0,0x0B7581,0x62BDC5};
        case ZNThemeModeSpaceBridge:   return {NO,YES,NO,ZNThemeDecorationSpace,     0x070B17,0x0B1226,0x091020,0x111B30,0x18243A,0xE9F6FF,0x8BA4BA,0x45D5FF,0x8A72FF,0x315C84,0x2D4057,0x0A1425,0x3BCFFF};
        case ZNThemeModeSteamWorkshop: return {NO,NO,YES,ZNThemeDecorationSteam,     0x17110C,0x24170C,0x1B130D,0x2E2116,0x3D2A19,0xFFE0A8,0xB89467,0xE88929,0xFFBF57,0x86522C,0x61452E,0x21150D,0xCE6D1F};
        case ZNThemeModeGothicArcane:  return {NO,YES,NO,ZNThemeDecorationGothic,    0x0E0714,0x160A20,0x11091A,0x1E102A,0x291536,0xF0E7F6,0xAA8EB8,0x9D4EDD,0xD64A8A,0x5F347A,0x44254E,0x170B20,0x9D4EDD};
        case ZNThemeModeCandyPop:      return {YES,NO,NO,ZNThemeDecorationCandy,     0xFFF4FA,0xFFF8FC,0xF9ECFF,0xFFFFFF,0xFFEAF6,0x442A55,0x8D6B9F,0xFF5BB7,0x6BCBFF,0xE5B4D5,0xF0D7E6,0xB95991,0xE47CB7};
        case ZNThemeModeInkWash:       return {YES,NO,NO,ZNThemeDecorationInk,       0xF1EFE8,0xF7F5EE,0xE6E2D8,0xFAF9F4,0xEDE9DF,0x282824,0x6A6962,0x3D6651,0xA7493D,0xA8A59A,0xCFCCC2,0x343832,0x77756D};
        case ZNThemeModePolarArmory:   return {NO,NO,YES,ZNThemeDecorationPolar,     0x101820,0x162431,0x111D28,0x1B2C39,0x253847,0xE8F4FA,0x8EA8B8,0x86D7FF,0xD7F4FF,0x496A7D,0x39505D,0x132633,0x8DDFFF};
        case ZNThemeModeLavaForge:     return {NO,YES,YES,ZNThemeDecorationLava,     0x140806,0x21100B,0x1A0C08,0x2C140D,0x3C1A10,0xFFF0DF,0xD19A78,0xFF5A1F,0xFFC04A,0x8C371F,0x5C2B1E,0x241008,0xFF4D1C};
        case ZNThemeModeDeepSeaSonar:  return {NO,YES,NO,ZNThemeDecorationSonar,     0x03131A,0x06232B,0x041B23,0x082C36,0x0B3943,0xDDFDFF,0x78AEB2,0x2EE6D6,0x73FFF2,0x1F6670,0x17454A,0x05252D,0x20DACC};
        case ZNThemeModeRetroArcade:   return {NO,YES,NO,ZNThemeDecorationArcade,    0x13091E,0x221036,0x170B26,0x2A123E,0x35184A,0xFFF7E8,0xC5A7D2,0xFF4FD8,0xFFD84F,0x71408F,0x4B2A62,0x1B0C2A,0xFF45D0};
        default:                       return {NO,NO,NO,ZNThemeDecorationObsidian,   0x11151B,0x171B21,0x14181E,0x20262E,0x2B323C,0xF2F4F7,0x9DA6B3,0x4D8DFF,0x79A8FF,0x8792A3,0x434A54,0x151A22,0x000000};
    }
}

+ (void)applySpec:(ZNThemeSpec)s toTheme:(ZNTheme *)t {
    t.lightAppearance = s.light;
    t.neonAppearance = s.neon;
    t.mechanicalAppearance = s.mechanical;
    t.decorationStyle = s.decoration;
    t.panelColor = ZNHexColor(s.panel, 0.965);
    t.headerColor = ZNHexColor(s.header, 0.985);
    t.sidebarColor = ZNHexColor(s.sidebar, 0.975);
    t.cardColor = ZNHexColor(s.card, s.light ? 0.90 : 0.94);
    t.popoverColor = ZNHexColor(s.control, 0.995);
    t.controlColor = ZNHexColor(s.control, 0.98);
    t.footerColor = ZNHexColor(s.header, 0.99);
    t.primaryTextColor = ZNHexColor(s.primary, 1.0);
    t.secondaryTextColor = ZNHexColor(s.secondary, 1.0);
    t.accentColor = ZNHexColor(s.accent, 1.0);
    t.accent2Color = ZNHexColor(s.accent2, 1.0);
    t.separatorColor = ZNHexColor(s.border, 0.18);
    t.borderColor = ZNHexColor(s.border, 0.54);
    t.selectedColor = ZNHexColor(s.accent, 0.20);
    t.trackColor = ZNHexColor(s.track, 0.44);
    t.floatColor = ZNHexColor(s.floating, 0.99);
    t.shadowColor = ZNHexColor(s.shadow, s.neon ? 0.72 : 0.38);
}

+ (UIColor *)indicatorColorForMode:(ZNThemeMode)mode {
    if (mode == ZNThemeModeSystem) return ZNHexColor(0xAEB8C5, 1.0);
    ZNThemeSpec s = [self specForMode:mode];
    return ZNHexColor(s.accent, 1.0);
}

+ (ZNTheme *)themeForMode:(ZNThemeMode)mode interfaceStyle:(UIUserInterfaceStyle)style {
    if (mode < ZNThemeModeSystem || mode >= ZNThemeModeCount) mode = ZNThemeModeObsidian;
    ZNTheme *t = [ZNTheme new];
    t.mode = mode;
    t.name = [self nameForMode:mode];

    if (mode == ZNThemeModeSystem) {
        BOOL dark = (style == UIUserInterfaceStyleDark);
        ZNThemeSpec s = dark
            ? (ZNThemeSpec){NO,NO,NO,ZNThemeDecorationMinimal,0x15181E,0x1A1E25,0x171A20,0x232831,0x2B313B,0xF3F5F8,0xAAB1BC,0x4B8DFF,0x74A7FF,0x657080,0x46505E,0x11151B,0x000000}
            : (ZNThemeSpec){YES,NO,NO,ZNThemeDecorationMinimal,0xF6F8FB,0xFBFCFE,0xF0F3F8,0xFFFFFF,0xEEF2F7,0x18202A,0x687383,0x3478F6,0x64A0FF,0x8AA1BB,0xC9D3DF,0x244B84,0x45678E};
        [self applySpec:s toTheme:t];
        return t;
    }

    [self applySpec:[self specForMode:mode] toTheme:t];
    return t;
}

@end
