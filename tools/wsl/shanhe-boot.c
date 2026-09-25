/* 山河烬 实机验收 v6：稳健推进 + 密集截图，目标是截到显示「虞聪」的画面。
 *
 * 相比 v5 的改动：
 *   1) 删掉"9000 帧后连按 Start"——它会在菜单里乱跳，反而卡住流程。
 *   2) 推进键间隔从 60 帧放宽到 90 帧，避开打字机动画（A 按太快会被吞）。
 *   3) 全程每 300 帧截一张，事后挑图，不依赖"精确猜到某一帧"。
 *   4) 保留 B 键定期"退出"，防止卡在子菜单里出不来。
 *
 * 用法：./shanhe-boot6 <rom> <outdir> <maxframes>
 */
#include <mgba/core/core.h>
#include <mgba/core/config.h>
#include <mgba/core/interface.h>
#include <mgba-util/vfs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { K_A = 1 << 0, K_B = 1 << 1, K_SEL = 1 << 2, K_START = 1 << 3,
       K_R = 1 << 4, K_L = 1 << 5, K_UP = 1 << 6, K_DOWN = 1 << 7,
       K_RT = 1 << 8, K_LT = 1 << 9 };

static void write_ppm(const char *path, const color_t *buf, unsigned w, unsigned h) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    for (unsigned i = 0; i < w * h; ++i) {
        color_t c = buf[i];
        unsigned char px[3] = {
            (unsigned char)((c & 0x1F) * 255 / 31),
            (unsigned char)(((c >> 5) & 0x1F) * 255 / 31),
            (unsigned char)(((c >> 10) & 0x1F) * 255 / 31)
        };
        fwrite(px, 1, 3, f);
    }
    fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <rom> <outdir> [maxframes]\n", argv[0]); return 2; }
    const char *rom = argv[1];
    const char *outdir = argv[2];
    long maxf = (argc > 3) ? atol(argv[3]) : 20000;

    struct mCore *core = mCoreFind(rom);
    if (!core) { fprintf(stderr, "mCoreFind failed\n"); return 1; }
    core->init(core);
    mCoreInitConfig(core, NULL);
    unsigned w = 240, h = 160;
    core->desiredVideoDimensions(core, &w, &h);
    color_t *vidbuf = malloc(w * h * sizeof(color_t));
    core->setVideoBuffer(core, vidbuf, w);
    struct VFile *vf = VFileOpen(rom, O_RDONLY);
    if (!vf || !core->loadROM(core, vf)) { fprintf(stderr, "loadROM failed\n"); return 1; }
    core->reset(core);

    unsigned held = 0;
    long hold_until = 0;
    long snap_i = 0;

    for (long f = 0; f < maxf; ++f) {
        /* ---- 输入策略：纯 A 单击推进，间隔 100 帧 ----
         * 实测：插 Start 会在战斗地图上反复开关菜单 → 崩溃
         *      （GBA Memory: Jumped to invalid address）。
         * 所以坚持纯 A。序章对话极长，需跑到 ~100000 帧才进战斗地图。
         * 密集截图（每 100 帧）便于事后定位关键画面。 */
        unsigned key = 0;
        if (f % 100 == 0) key = K_A;

        if (key) { held = key; hold_until = f + 8; }
        if (f >= hold_until) held = 0;

        core->setKeys(core, held);
        core->runFrame(core);

        /* 每 500 帧截一张（约 8.3 秒），平衡覆盖度与磁盘占用 */
        if (f >= 500 && f % 500 == 0) {
            char p[512];
            snprintf(p, sizeof(p), "%s/S%06ld.ppm", outdir, f);
            write_ppm(p, vidbuf, w, h);
            snap_i++;
        }
    }
    printf("DONE snaps=%ld\n", snap_i);
    free(vidbuf);
    core->deinit(core);
    return 0;
}
