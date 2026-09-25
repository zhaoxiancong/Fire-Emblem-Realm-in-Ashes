/* 山河烬 实机验收 v7：定点密集截取（用于捕捉战斗地图上的「虞聪」名字框）。
 *
 * 背景：全流程跑 10 万帧太慢且易崩；已知战斗地图出现在约 37000~39000 帧
 *      （由 shots6 的每 500 帧截图定位：S037000 教学提示 → S038000 战斗地图）。
 * 策略：纯 A 推进到 START 帧，之后每 STEP 帧截一张，共 N 张后退出。
 *
 * 用法：./shanhe-boot-range <rom> <outdir> <start> <count> [step]
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
    if (argc < 5) { fprintf(stderr, "usage: %s <rom> <outdir> <start> <count> [step]\n", argv[0]); return 2; }
    const char *rom = argv[1], *outdir = argv[2];
    long start = atol(argv[3]);
    long count = atol(argv[4]);
    long step = (argc > 5) ? atol(argv[5]) : 50;
    long end = start + count * step;

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
    long snaps = 0;

    for (long f = 0; f < end; ++f) {
        /* 一直是纯 A 单击推进（间隔 100 帧）——不插 Start/B，避免崩溃 */
        if (f % 100 == 0) { held = K_A; hold_until = f + 8; }
        if (f >= hold_until) held = 0;
        core->setKeys(core, held);
        core->runFrame(core);

        /* 只在 [start, end) 区间截图，且对齐 step 网格 */
        if (f >= start && (f - start) % step == 0) {
            char p[512];
            snprintf(p, sizeof(p), "%s/R%06ld.ppm", outdir, f);
            write_ppm(p, vidbuf, w, h);
            snaps++;
        }
    }
    printf("DONE snaps=%ld\n", snaps);
    free(vidbuf);
    core->deinit(core);
    return 0;
}
