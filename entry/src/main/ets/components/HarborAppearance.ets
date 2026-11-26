export class Palette {
  static readonly rail: Resource = $r('app.color.rail');
  static readonly railSelected: Resource = $r('app.color.rail_selected');
  static readonly railText: Resource = $r('app.color.rail_text');
  static readonly railMuted: Resource = $r('app.color.rail_muted');
  static readonly mint: Resource = $r('app.color.mint');
  static readonly canvas: Resource = $r('app.color.canvas');
  static readonly surface: Resource = $r('app.color.surface');
  static readonly soft: Resource = $r('app.color.surface_soft');
  static readonly line: Resource = $r('app.color.separator');
  static readonly ink: Resource = $r('app.color.ink');
  static readonly muted: Resource = $r('app.color.ink_muted');
  static readonly accent: Resource = $r('app.color.accent');
  static readonly onAccent: Resource = $r('app.color.on_accent');
  static readonly selected: Resource = $r('app.color.selected');
  static readonly amber: Resource = $r('app.color.status_warning');
  static readonly danger: Resource = $r('app.color.status_danger');
  static readonly dangerSoft: Resource = $r('app.color.status_danger_soft');
}

const ICON_PATHS = new Map<string, string>([
  ['anchor', 'M10 7 V17 M7 10 H13 M3 12 C3 15 6 17 10 17 C14 17 17 15 17 12 M3 12 L5 13 M17 12 L15 13 M12 5 A2 2 0 1 1 8 5 A2 2 0 1 1 12 5'],
  ['list', 'M4 4 H16 V16 H4 Z M4 8 H16 M8 8 V16'],
  ['activity', 'M2 10 H5 L8 4 L11 16 L14 10 H18'],
  ['pause', 'M7 5 V15 M13 5 V15'],
  ['disabled', 'M16 10 A6 6 0 1 1 4 10 A6 6 0 1 1 16 10 M6 14 L14 6'],
  ['warning', 'M10 3 L18 16 H2 Z M10 8 V11 M10 13.4 V13.5'],
  ['device', 'M3 4 H17 V13 H3 Z M10 13 V16 M7 16 H13'],
  ['layers', 'M10 3 L17 7 L10 11 L3 7 Z M3 10.5 L10 14.5 L17 10.5 M3 14 L10 18 L17 14'],
  ['terminal', 'M3 4 H17 V16 H3 Z M6 8 L8.5 10 L6 12 M11 12 H14'],
  ['refresh', 'M16.5 7.5 A7 7 0 1 0 16.5 12.5 M16.5 3.5 V7.5 H12.5'],
  ['search', 'M13 8 A5 5 0 1 1 3 8 A5 5 0 1 1 13 8 M12 12 L17 17'],
  ['chevron', 'M8 5 L13 10 L8 15']
]);

@Component
export struct HarborIcon {
  @Prop name: string;
  @Prop tint: ResourceColor;
  @Prop iconSize: number = 20;

  build() {
    Shape() {
      Path().commands(ICON_PATHS.get(this.name) ?? '').fillOpacity(0)
        .stroke(this.tint).strokeWidth('1.7px').strokeLineCap(LineCapStyle.Round).strokeLineJoin(LineJoinStyle.Round)
    }
    // Path commands use pixels. Scale that coordinate system into a density-independent icon box.
    .viewPort({ x: 0, y: 0, width: '20px', height: '20px' }).width(this.iconSize).height(this.iconSize)
    .accessibilityLevel('no')
  }
}
