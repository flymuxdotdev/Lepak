// main/ib_ui_offline.c: OFFLINE 页:Mac 未连接时的点阵时钟(全宽,无提示列)。
//
// Lepak:布局用原版 InputBetter 0.1.3 的离线页(用户 2026-11-16 定的:不要猫咪背景图),
// 配色和标题沿用本固件其它页面的 Matrix 风格:左上角 "> OFFLINE_" 终端标题,暗绿细框里一组绿色点阵。
// - 时钟:5x7 点阵数字(4 位 + 冒号正好 25 列,点距 8 px,铺满 200 px,居中),冒号 1 s 一闪表示"活着"。
// - 下方日期,再下方一行提示(ib_app 给的配对 / 链路状态,默认 "WAITING FOR MAC")。
// - 蓝牙配对时(ctx->pair_code 非空):时钟换成两行三位的点阵配对码,下面说明在 Mac 上输入。
// 只有冒号逐帧变化:每帧只 invalidate 冒号那一小块;时间文字每分钟由 ib_app 更新一次。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

// 以下 y 都相对页面(状态栏下方)。
#define CLOCK_X0    24                      // 第 0 列点心 x(24 + 8c,c = 0..24)
#define CLOCK_Y     (76 - IB_UI_BAR_H)      // 时钟控件顶部:点阵行 0..6 → 屏幕 y 92..140(与原版一致)
#define CLOCK_H     80
#define CLOCK_PAD   16                      // 控件内第 0 行点心 y
#define COLON_COL   12
#define DATE_CY     (172 - IB_UI_BAR_H)
#define WAIT_CY     (240 - IB_UI_BAR_H)
#define BLINK_MS    1000

// 配对码:两行,每行 3 位(3 x 5 列 + 2 列间隔 = 17 列),行间空 2 行。
#define CODE_X0     ((IB_UI_W - 16 * IB_DOTS_PITCH) / 2)
#define CODE_Y      (68 - IB_UI_BAR_H)
#define CODE_PAD    14
#define CODE_H      (CODE_PAD * 2 + 15 * IB_DOTS_PITCH)
#define CODE_NOTE_CY (232 - IB_UI_BAR_H)
#define CODE_HINT_CY (252 - IB_UI_BAR_H)

// 5x7 数字字模(每行 5 位,高位在左)。
static const uint8_t DIGITS[10][7] = {
    { 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E }, { 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
    { 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F }, { 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E },
    { 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 }, { 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
    { 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E }, { 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
    { 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E }, { 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
};
// 4 位数字的起始列(冒号在第 12 列)。
static const int8_t DIGIT_COL[4] = { 0, 6, 14, 20 };

static lv_obj_t *s_title;
static lv_obj_t *s_clock;
static lv_obj_t *s_code;
static lv_obj_t *s_date;
static lv_obj_t *s_hint;
static lv_obj_t *s_code_note;
static lv_obj_t *s_code_hint;
static char s_time[8];
static char s_pair[8];                      // 配对码 "123456"
static int32_t s_colon;                     // 冒号亮度 0..IB_P_ONE

static void draw_digit(const ib_fx_t *fx, char ch, int32_t x0, int32_t y0, lv_color_t on)
{
    if (ch < '0' || ch > '9') return;
    const uint8_t *g = DIGITS[ch - '0'];
    for (int r = 0; r < 7; r++) {
        for (int c = 0; c < 5; c++) {
            if (g[r] & (0x10 >> c)) ib_dots_dot(fx, x0 + c * IB_DOTS_PITCH, y0 + r * IB_DOTS_PITCH, on, 0);
        }
    }
}

static int32_t clock_x(int32_t c)
{
    return CLOCK_X0 + c * IB_DOTS_PITCH;
}

static void clock_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    // 和 READY 页一样的暗绿细框。
    ib_fx_frame(&fx, 6, 2, IB_UI_W - 12, CLOCK_H - 4, 0, 1, IB_C(IB_COLOR_MATRIX_FRAME), LV_OPA_COVER);
    lv_color_t on = IB_C(IB_COLOR_MATRIX_SOFT);
    // "HH:MM";未知时间(--:--)只画两条短横。
    int k = 0;
    for (const char *p = s_time; *p && k < 4; p++) {
        if (*p == ':') continue;
        int8_t c0 = DIGIT_COL[k++];
        if (*p < '0' || *p > '9') {
            for (int c = 1; c < 4; c++) {
                ib_dots_dot(&fx, clock_x(c0 + c), CLOCK_PAD + 3 * IB_DOTS_PITCH, IB_C(IB_COLOR_MATRIX_FRAME), 0);
            }
            continue;
        }
        draw_digit(&fx, *p, clock_x(c0), CLOCK_PAD, on);
    }
    lv_color_t colon = lv_color_mix(IB_C(IB_COLOR_MATRIX_SOFT), IB_C(IB_COLOR_MATRIX_FRAME),
                                     (uint8_t)(s_colon * 255 / IB_P_ONE));
    ib_dots_dot(&fx, clock_x(COLON_COL), CLOCK_PAD + 2 * IB_DOTS_PITCH, colon, 0);
    ib_dots_dot(&fx, clock_x(COLON_COL), CLOCK_PAD + 4 * IB_DOTS_PITCH, colon, 0);
}

static void code_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    ib_fx_frame(&fx, 6, 2, IB_UI_W - 12, CODE_H - 4, 0, 1, IB_C(IB_COLOR_MATRIX_FRAME), LV_OPA_COVER);
    lv_color_t on = IB_C(IB_COLOR_MATRIX_BRIGHT);
    for (int i = 0; i < 6 && s_pair[i]; i++) {
        int32_t x0 = CODE_X0 + (i % 3) * 6 * IB_DOTS_PITCH;
        int32_t y0 = CODE_PAD + (i / 3) * 9 * IB_DOTS_PITCH;
        draw_digit(&fx, s_pair[i], x0, y0, on);
    }
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    // 离线页的根铺满整屏(ib_ui 不把它下移);内容放进状态栏下方的页面区,坐标与其它页一致。
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_W, IB_UI_H);
    lv_obj_t *page = ib_box_create(root, 0, IB_UI_BAR_H, IB_UI_W, IB_UI_PAGE_H);
    s_title = ib_label_create(page, &ib_terminal_font_20, IB_COLOR_MATRIX_SOFT, 0, IB_UI_W - 20);
    lv_obj_set_style_text_align(s_title, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_align(s_title, LV_ALIGN_TOP_LEFT, 10, 5);
    lv_label_set_text_static(s_title, "> OFFLINE_");

    s_clock = ib_fx_create(page, 0, CLOCK_Y, IB_UI_W, CLOCK_H, clock_draw, NULL);
    s_date = ib_caption_create(page, IB_COLOR_TEXT_MID, ib_font_top(&lv_font_montserrat_12, DATE_CY), IB_UI_W, 2);
    s_hint = ib_caption_create(page, IB_COLOR_TEXT_DIM, ib_font_top(&lv_font_montserrat_12, WAIT_CY), IB_UI_W, 1);

    s_code = ib_fx_create(page, 0, CODE_Y, IB_UI_W, CODE_H, code_draw, NULL);
    s_code_note = ib_caption_create(page, IB_COLOR_TEXT_MID, ib_font_top(&lv_font_montserrat_12, CODE_NOTE_CY),
                                    IB_UI_W, 1);
    s_code_hint = ib_caption_create(page, IB_COLOR_TEXT_DIM, ib_font_top(&lv_font_montserrat_12, CODE_HINT_CY),
                                    IB_UI_W, 1);
    lv_label_set_text_static(s_code_note, "TYPE THIS CODE ON YOUR MAC");
    lv_label_set_text_static(s_code_hint, "CODE EXPIRES IN 90 SECONDS");
    lv_obj_add_flag(s_code, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(s_code_note, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(s_code_hint, LV_OBJ_FLAG_HIDDEN);
    return root;
}

static void show(lv_obj_t *obj, bool visible)
{
    if (visible) lv_obj_remove_flag(obj, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
}

static void update(const ib_ui_ctx_t *ctx)
{
    bool pairing = ctx->pair_code[0] != '\0';
    show(s_clock, !pairing);
    show(s_date, !pairing);
    show(s_hint, !pairing);
    show(s_code, pairing);
    show(s_code_note, pairing);
    show(s_code_hint, pairing);
    if (pairing) {
        // 蓝牙配对:点阵大字显示配对码,让用户在 Mac 弹出的系统配对窗口里输入。
        lv_label_set_text_static(s_title, "> PAIR_");
        lv_snprintf(s_pair, sizeof(s_pair), "%s", ctx->pair_code);
        lv_obj_invalidate(s_code);
        return;
    }
    lv_label_set_text_static(s_title, "> OFFLINE_");
    lv_snprintf(s_time, sizeof(s_time), "%s", ctx->time[0] ? ctx->time : "--:--");
    lv_label_set_text(s_date, ctx->time[0] ? ctx->date : "");
    lv_label_set_text_static(s_hint, ctx->offline_hint[0] ? ctx->offline_hint : "WAITING FOR MAC");
    lv_obj_invalidate(s_clock);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    if (ctx->pair_code[0]) return;
    // 冒号:亮 ↔ 暗的柔和正弦,1 s 一个周期。
    s_colon = IB_P_ONE - ib_ease_in_out_sine(ib_breath(ctx->now_ms, BLINK_MS));
    lv_area_t a;
    lv_obj_get_coords(s_clock, &a);
    int32_t x = a.x1 + clock_x(COLON_COL);
    lv_area_t colon = { x - 4, a.y1, x + 4, a.y2 };
    lv_obj_invalidate_area(s_clock, &colon);
}

const ib_ui_page_t ib_ui_page_offline = { create, enter, update, frame };
