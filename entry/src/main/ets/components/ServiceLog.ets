import fileIo from '@ohos.file.fs';
import util from '@ohos.util';
import { Palette } from './HarborAppearance';

const MAX_BYTES = 24 * 1024;
const MAX_LINES = 80;

async function readLogTail(path: string): Promise<string> {
  const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NONBLOCK);
  try {
    const info = await fileIo.stat(file.fd);
    if (!info.isFile()) throw new Error('The log path is not a regular file');
    const length = Math.min(info.size, MAX_BYTES);
    if (length === 0) return '';
    const offset = info.size - length;
    const buffer = new ArrayBuffer(length);
    const bytesRead = await fileIo.read(file.fd, buffer, { offset: offset, length: length });
    const bytes = new Uint8Array(buffer, 0, bytesRead);
    // Skip any UTF-8 continuation bytes left at the start of the captured tail.
    let start = 0;
    while (start < bytes.length && (bytes[start] & 0xc0) === 0x80) start++;
    let text = util.TextDecoder.create('utf-8').decodeToString(bytes.subarray(start));
    const firstLineEnd = text.indexOf('\n');
    if (offset > 0 && firstLineEnd >= 0) text = text.slice(firstLineEnd + 1);
    return text.trimEnd().split('\n').slice(-MAX_LINES).join('\n');
  } finally {
    await fileIo.close(file);
  }
}

@Component
export struct ServiceLog {
  @Prop @Watch('onPathChange') path: string = '';
  @State private output: string = '';
  @State private message: string = '正在读取日志…';
  private timer: number = -1;
  private generation: number = 0;
  private reading: boolean = false;

  aboutToAppear(): void {
    this.onPathChange();
    this.timer = setInterval(() => { void this.refresh(); }, 5000);
  }

  aboutToDisappear(): void {
    this.generation++;
    clearInterval(this.timer);
  }

  private onPathChange(): void {
    this.generation++;
    this.reading = false;
    this.output = '';
    this.message = this.path ? '正在读取日志…' : '此服务未配置日志文件';
    void this.refresh();
  }

  private async refresh(): Promise<void> {
    if (!this.path || this.reading) return;
    this.reading = true;
    const generation = this.generation;
    try {
      const output = await readLogTail(this.path);
      if (generation === this.generation) {
        this.output = output;
        this.message = '日志文件为空';
      }
    } catch (error) {
      if (generation === this.generation) {
        this.output = '';
        this.message = '无法读取日志，请检查文件是否存在及读取权限';
      }
    } finally {
      if (generation === this.generation) this.reading = false;
    }
  }

  build() {
    Column({ space: 10 }) {
      if (this.path) {
        Text(this.path).fontSize(11).fontFamily('monospace').fontColor(Palette.muted)
          .copyOption(CopyOptions.LocalDevice).wordBreak(WordBreak.BREAK_ALL).maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.output) {
        Text('最近日志').fontSize(12).fontColor(Palette.muted)
        Scroll() {
          Text(this.output).width('100%').padding(12).fontSize(12).lineHeight(19).fontFamily('monospace')
            .fontColor(Palette.railText).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
        }
        .width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
        .borderRadius(8).backgroundColor(Palette.rail).clip(true)
      } else {
        Text(this.message).fontSize(13).fontColor(Palette.muted)
      }
    }
    .width('100%').layoutWeight(1).alignItems(HorizontalAlign.Start).padding(18)
  }
}
