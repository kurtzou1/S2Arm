package org.s2arm.android;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorMatrix;
import android.graphics.ColorMatrixColorFilter;
import android.graphics.Outline;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.view.animation.DecelerateInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

/**
 * 游戏库横屏页，照 iOS 的 shell/Sources/ShellUI/CoverFlowView.swift 搭：模糊封面做底、左上「你的游戏 第 N 个，共 M」、
 * 右上三个圆钮（游戏设置 / 手柄数 / 设置）、正中一张 16:9 封面卡片（左上角状态点），两侧卡片转过去、缩小、压暗，卡片下面是游戏名。
 * 卡片尺寸与邻卡的转角 / 缩放 / 位移 / 压暗按 iOS 的公式算（cardHeight、CoverTransform），只用系统 View，不引第三方库。
 */
final class LibraryShelf extends FrameLayout {
    interface Listener {
        void play(String titleId);
        void openGameSettings();
        void openControllers();
        void openSettings();
    }

    private static final int BACKGROUND = Color.rgb(14, 14, 15);     // ShellPalette.background
    private static final int READY = Color.rgb(64, 214, 120);        // ShellPalette.ready

    private static final class Game {
        final String id, title; final Bitmap art, thumb; final View card;
        Game(String id, String title, Bitmap art, Bitmap thumb, View card) { this.id = id; this.title = title; this.art = art; this.thumb = thumb; this.card = card; }
    }

    private final Listener listener;
    private final float dp;
    private final List<Game> games = new ArrayList<>();
    private final ImageView backdrop;
    private final FrameLayout deck;
    private final TextView position, title, empty, controllerCount;
    private final int touchSlop;
    private float offset;          // 卡片单位：0 = 第一张在正中
    private float cover = 1;       // 卡片宽（像素）
    private ValueAnimator settle;
    private VelocityTracker velocity;
    private float downX, downOffset;
    private boolean dragging;
    private int shown = -1;

    LibraryShelf(Context context, Listener listener) {
        super(context);
        this.listener = listener;
        dp = context.getResources().getDisplayMetrics().density;
        touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
        setBackgroundColor(BACKGROUND);

        backdrop = new ImageView(context);
        backdrop.setScaleType(ImageView.ScaleType.CENTER_CROP);
        backdrop.setScaleX(1.3f); backdrop.setScaleY(1.3f);
        backdrop.setAlpha(0.75f);
        ColorMatrix saturate = new ColorMatrix(); saturate.setSaturation(1.25f);
        backdrop.setColorFilter(new ColorMatrixColorFilter(saturate));
        // CoverFlowBackdrop 的 blur(radius: 60)：安卓 12 起用系统模糊；更早的系统靠 48 像素小图放大（Artwork.thumbnail 同一个办法）
        if (android.os.Build.VERSION.SDK_INT >= 31)
            backdrop.setRenderEffect(android.graphics.RenderEffect.createBlurEffect(60 * dp, 60 * dp, Shader.TileMode.CLAMP));
        addView(backdrop, new LayoutParams(-1, -1));
        addView(new Shade(context), new LayoutParams(-1, -1));

        deck = new FrameLayout(context);
        deck.setClipChildren(false);
        addView(deck, new LayoutParams(-1, -1));

        title = text(context, 18, Typeface.BOLD, 0xFFFFFFFF);
        title.setGravity(Gravity.CENTER); title.setMaxLines(2); title.setEllipsize(TextUtils.TruncateAt.END);
        title.setShadowLayer(10 * dp, 0, 0, 0x59000000);
        title.setLetterSpacing(-0.04f);
        addView(title, new LayoutParams(-1, -2, Gravity.TOP));

        empty = text(context, 18, Typeface.BOLD, 0xFFFFFFFF);
        empty.setGravity(Gravity.CENTER);
        empty.setText(context.getString(R.string.library_empty) + "\n" + context.getString(R.string.library_empty_hint));
        empty.setLineSpacing(6 * dp, 1);
        addView(empty, new LayoutParams(-1, -2, Gravity.CENTER));

        LinearLayout bar = new LinearLayout(context);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding((int) (24 * dp), (int) (12 * dp), (int) (24 * dp), 0);
        TextView heading = text(context, 13, Typeface.BOLD, 0xD9FFFFFF);
        heading.setText(R.string.library_your_games); heading.setLetterSpacing(0.12f);
        bar.addView(heading);
        position = text(context, 12, Typeface.NORMAL, 0x73FFFFFF);
        position.setPadding((int) (14 * dp), 0, 0, 0);
        bar.addView(position);
        bar.addView(new View(context), new LinearLayout.LayoutParams(0, 1, 1));
        bar.addView(chip(context, Chip.SLIDERS, null, v -> listener.openGameSettings()));
        controllerCount = text(context, 13, Typeface.BOLD, 0xFFFFFFFF);
        bar.addView(chip(context, Chip.PAD, controllerCount, v -> listener.openControllers()));
        bar.addView(chip(context, Chip.GEAR, null, v -> listener.openSettings()));
        addView(bar, new LayoutParams(-1, -2, Gravity.TOP));
        setControllers(0);
        refresh();
    }

    /** art 可为 null（画占位）。同一款再报一次只换名字和图。 */
    void addGame(String titleId, String name, File art) {
        Bitmap image = art == null ? null : BitmapFactory.decodeFile(art.getPath());
        Bitmap thumb = image == null ? null : Bitmap.createScaledBitmap(image, 48, Math.max(1, 48 * image.getHeight() / Math.max(1, image.getWidth())), true);
        for (int i = 0; i < games.size(); i++) if (games.get(i).id.equals(titleId)) {
            deck.removeView(games.get(i).card);
            games.set(i, new Game(titleId, name, image, thumb, card(image)));
            deck.addView(games.get(i).card);
            shown = -1; requestLayout(); return;
        }
        games.add(new Game(titleId, name, image, thumb, card(image)));
        deck.addView(games.get(games.size() - 1).card);
        shown = -1; requestLayout();
    }

    void setControllers(int count) { controllerCount.setText(String.valueOf(count)); }

    String selectedId() { int i = selected(); return i < 0 ? null : games.get(i).id; }

    private int selected() { return games.isEmpty() ? -1 : Math.max(0, Math.min(games.size() - 1, Math.round(offset))); }

    @Override protected void onLayout(boolean changed, int l, int t, int r, int b) {
        super.onLayout(changed, l, t, r, b);
        layoutDeck();
    }

    // 照 CoverFlowView.body：卡片在整屏正中，上面留顶栏，下面留两行标题 + 一行状态。
    private void layoutDeck() {
        float w = getWidth() / dp, h = getHeight() / dp;
        if (w <= 0 || h <= 0) return;
        boolean shortScreen = h < 520;
        float middle = h / 2, gap = shortScreen ? 10 : 24, size = shortScreen ? 18 : 28;
        float words = size * 1.3f * 2 + 8 + 34, below = shortScreen ? 4 : 56;
        float byBottom = 2 * (h - middle - gap - words - below);
        float byTop = 2 * (middle - (shortScreen ? 12 : 16) - 44 - (shortScreen ? 6 : 16));
        float cardHeight = Math.max(90, Math.min(Math.min(byBottom, byTop), w * 0.54f * 9 / 16) / 1.06f);
        cover = cardHeight * 16 / 9 * dp;
        int cw = Math.round(cover), ch = Math.round(cover * 9 / 16);
        for (Game g : games) {
            // 横向居中、纵向按 middle 放，靠布局参数定位；平移量只留给 place() 做左右错开
            LayoutParams lp = (LayoutParams) g.card.getLayoutParams();
            int top = Math.round(middle * dp - ch / 2f);
            if (lp.width != cw || lp.height != ch || lp.topMargin != top || lp.gravity != (Gravity.TOP | Gravity.CENTER_HORIZONTAL)) {
                lp.width = cw; lp.height = ch; lp.topMargin = top; lp.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL; g.card.setLayoutParams(lp);
            }
            g.card.setPivotX(cw / 2f); g.card.setPivotY(ch / 2f);
        }
        if (title.getTextSize() != size * getResources().getDisplayMetrics().scaledDensity) title.setTextSize(size);   // 只在变了时设：设字号会再触发一次布局
        title.setY(middle * dp + cardHeight * 1.06f * dp / 2 + gap * dp);
        place();
    }

    // CoverTransform：近处 ±1 内转 30°、缩 22%、往里收 0.28 张、压暗 25%；再远每张收 0.55 张、再暗 10%。
    private void place() {
        float stride = cover * 1.04f;
        for (int i = 0; i < games.size(); i++) {
            View c = games.get(i).card;
            float p = i - offset, near = Math.max(-1, Math.min(1, p)), tilt = Math.max(-1.5f, Math.min(1.5f, p));
            float far = p > 1 ? p - 1 : p < -1 ? p + 1 : 0;
            c.setCameraDistance(cover * 8);
            c.setRotationY(-tilt * 30);
            float s = 1 - Math.abs(near) * 0.22f;
            c.setScaleX(s); c.setScaleY(s);
            c.setTranslationX(p * stride - near * cover * 0.28f - far * cover * 0.55f);
            View shade = ((ViewGroup) c).getChildAt(2);
            shade.setAlpha(Math.abs(near) * 0.25f + Math.min(Math.abs(far), 1) * 0.1f);   // brightness(-|near|·0.25 − min(|far|,1)·0.1)
            c.setElevation(Math.max(0, 8 - Math.abs(p) * 4) * dp);
            c.setVisibility(Math.abs(p) > 3.5f ? INVISIBLE : VISIBLE);
        }
        refresh();
    }

    private void refresh() {
        int i = selected();
        empty.setVisibility(games.isEmpty() ? VISIBLE : GONE);
        title.setVisibility(games.isEmpty() ? GONE : VISIBLE);
        // 只在变了时设文字：setText 会请求重新布局，而 refresh 本身就在布局里调（11-13 空库时主线程因此一直空转）
        setIfChanged(position, games.isEmpty() ? "" : getContext().getString(R.string.library_position, i + 1, games.size()));
        if (i == shown) return;
        shown = i;
        if (i < 0) { backdrop.setImageDrawable(null); return; }
        Game g = games.get(i);
        title.setText(g.title);
        backdrop.setImageBitmap(g.thumb);   // 48 像素小图放大即模糊（iOS 的 Artwork.thumbnail 同一个办法）
    }

    private static void setIfChanged(TextView t, CharSequence s) { if (!TextUtils.equals(t.getText(), s)) t.setText(s); }

    @Override public boolean onInterceptTouchEvent(MotionEvent e) {
        if (e.getActionMasked() == MotionEvent.ACTION_DOWN) { downX = e.getX(); downOffset = offset; dragging = false; }
        return e.getActionMasked() == MotionEvent.ACTION_MOVE && Math.abs(e.getX() - downX) > touchSlop && !games.isEmpty() && onDeck(e);
    }

    private boolean onDeck(MotionEvent e) { return e.getY() > 64 * dp; }   // 顶栏的圆钮照常点

    @Override public boolean onTouchEvent(MotionEvent e) {
        if (games.isEmpty()) return false;
        if (velocity == null) velocity = VelocityTracker.obtain();
        velocity.addMovement(e);
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                if (settle != null) settle.cancel();
                downX = e.getX(); downOffset = offset; dragging = false; return true;
            case MotionEvent.ACTION_MOVE:
                if (!dragging && Math.abs(e.getX() - downX) > touchSlop) dragging = true;
                if (dragging) {
                    float raw = downOffset - (e.getX() - downX) / (cover * 1.04f), lo = 0, hi = games.size() - 1;
                    offset = raw < lo ? lo - rubber(lo - raw) : raw > hi ? hi + rubber(raw - hi) : raw;   // 两头带回弹
                    place();
                }
                return true;
            case MotionEvent.ACTION_UP:
                velocity.computeCurrentVelocity(1000);
                float v = -velocity.getXVelocity() / (cover * 1.04f);
                velocity.recycle(); velocity = null;
                if (dragging) {
                    int start = Math.round(downOffset), target = Math.round(offset + v * 0.12f);
                    target = Math.max(start - 1, Math.min(start + 1, target));   // 一次手势最多走一张（同 iOS）
                    animateTo(target);
                } else tap(e.getX(), e.getY());
                return true;
            case MotionEvent.ACTION_CANCEL:
                if (velocity != null) { velocity.recycle(); velocity = null; }
                animateTo(Math.round(offset)); return true;
        }
        return false;
    }

    private float rubber(float over) { return over / (1 + over * 3); }

    // 点正中那张 = 开始玩；点旁边的 = 先把它挪到正中（同 iOS coverButton）
    private void tap(float x, float y) {
        int hit = -1; float best = Float.MAX_VALUE;
        for (int i = 0; i < games.size(); i++) {
            View c = games.get(i).card;
            float cx = c.getX() + c.getWidth() / 2f, half = c.getWidth() * c.getScaleX() / 2;   // getX 已含平移量
            float top = c.getY() + c.getHeight() * (1 - c.getScaleY()) / 2, bottom = top + c.getHeight() * c.getScaleY();
            float d = Math.abs(x - cx);
            if (d <= half && y >= top && y <= bottom && Math.abs(i - offset) < best) { best = Math.abs(i - offset); hit = i; }
        }
        if (hit < 0) return;
        if (hit == selected() && Math.abs(offset - hit) < 0.01f) listener.play(games.get(hit).id);
        else animateTo(hit);
    }

    private void animateTo(int index) {
        int target = Math.max(0, Math.min(games.size() - 1, index));
        if (settle != null) settle.cancel();
        settle = ValueAnimator.ofFloat(offset, target);
        settle.setDuration(300); settle.setInterpolator(new DecelerateInterpolator(1.6f));
        settle.addUpdateListener(a -> { offset = (float) a.getAnimatedValue(); place(); });
        settle.start();
    }

    private View card(Bitmap art) {
        Context c = getContext();
        FrameLayout card = new FrameLayout(c);
        card.setClipToOutline(true);
        card.setOutlineProvider(new ViewOutlineProvider() {   // 圆角 = 卡片宽的 3%（同 iOS CoverView radius cover·0.03）；建卡片时设一次
            @Override public void getOutline(View view, Outline outline) { outline.setRoundRect(0, 0, view.getWidth(), view.getHeight(), view.getWidth() * 0.03f); }
        });
        card.setBackgroundColor(Color.rgb(26, 26, 28));
        ImageView image = new ImageView(c);
        if (art != null && art.getWidth() * 9 > art.getHeight() * 14) {   // 横图（商店封面）：铺满
            image.setScaleType(ImageView.ScaleType.CENTER_CROP); image.setImageBitmap(art);
        } else if (art != null) {                                           // 方图标：模糊的自己做底、图标居中
            ImageView under = new ImageView(c); under.setScaleType(ImageView.ScaleType.CENTER_CROP);
            under.setImageBitmap(Bitmap.createScaledBitmap(art, 24, 24, true)); under.setAlpha(0.8f);
            card.addView(under, new LayoutParams(-1, -1));
            image.setScaleType(ImageView.ScaleType.FIT_CENTER); image.setImageBitmap(art);
        }
        if (card.getChildCount() == 0) card.addView(new View(c), new LayoutParams(0, 0));   // 子视图固定：0 底 / 1 图 / 2 暗层 / 3 点
        card.addView(image, new LayoutParams(-1, -1));
        View shade = new View(c); shade.setBackgroundColor(0xFF000000); shade.setAlpha(0);
        card.addView(shade, new LayoutParams(-1, -1));
        View dot = new View(c);
        GradientDrawable round = new GradientDrawable(); round.setShape(GradientDrawable.OVAL); round.setColor(READY);
        round.setStroke((int) (2 * dp), 0x66FFFFFF);
        dot.setBackground(round);
        LayoutParams lp = new LayoutParams((int) (14 * dp), (int) (14 * dp), Gravity.TOP | Gravity.START);
        lp.leftMargin = lp.topMargin = (int) (12 * dp);
        card.addView(dot, lp);
        card.setLayoutParams(new LayoutParams(1, 1));
        return card;
    }

    private TextView text(Context c, float sp, int style, int color) {
        TextView t = new TextView(c); t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp); t.setTypeface(Typeface.create(Typeface.DEFAULT, style));
        t.setTextColor(color); return t;
    }

    private enum Chip { SLIDERS, PAD, GEAR }

    // ChipButtonStyle：44 高的胶囊，黑 50% 底 + 14% 白描边，白色图标；手柄钮带数字
    private View chip(Context c, Chip kind, TextView count, OnClickListener click) {
        LinearLayout box = new LinearLayout(c);
        box.setGravity(Gravity.CENTER);
        box.setMinimumHeight((int) (44 * dp)); box.setMinimumWidth((int) (44 * dp));
        box.setPadding((int) (14 * dp), 0, (int) (14 * dp), 0);
        GradientDrawable bg = new GradientDrawable(); bg.setCornerRadius(22 * dp); bg.setColor(0x80000000); bg.setStroke((int) Math.max(1, dp), 0x24FFFFFF);
        box.setBackground(bg);
        box.addView(new Glyph(c, kind), new LinearLayout.LayoutParams((int) (20 * dp), (int) (20 * dp)));
        if (count != null) { count.setPadding((int) (8 * dp), 0, 0, 0); box.addView(count); }
        box.setOnClickListener(click);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, (int) (44 * dp));
        lp.leftMargin = (int) (10 * dp);
        box.setLayoutParams(lp);
        return box;
    }

    /** 三个圆钮的线条图标（系统图标 slider.horizontal.3 / gamecontroller / gearshape 的同义画法）。 */
    private final class Glyph extends View {
        private final Chip kind; private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        Glyph(Context c, Chip kind) { super(c); this.kind = kind; p.setColor(0xFFFFFFFF); p.setStrokeWidth(1.8f * dp); p.setStrokeCap(Paint.Cap.ROUND); }
        @Override protected void onDraw(Canvas k) {
            float w = getWidth(), h = getHeight();
            switch (kind) {
                case SLIDERS:
                    p.setStyle(Paint.Style.STROKE);
                    float[] ys = {h * 0.22f, h * 0.5f, h * 0.78f}, knobs = {w * 0.65f, w * 0.32f, w * 0.55f};
                    for (int i = 0; i < 3; i++) {
                        k.drawLine(w * 0.08f, ys[i], w * 0.92f, ys[i], p);
                        p.setStyle(Paint.Style.FILL); p.setColor(0xFF000000); k.drawCircle(knobs[i], ys[i], w * 0.12f, p);
                        p.setColor(0xFFFFFFFF); p.setStyle(Paint.Style.STROKE); k.drawCircle(knobs[i], ys[i], w * 0.12f, p);
                    }
                    break;
                case PAD:
                    p.setStyle(Paint.Style.STROKE);
                    k.drawRoundRect(w * 0.04f, h * 0.24f, w * 0.96f, h * 0.8f, h * 0.28f, h * 0.28f, p);
                    k.drawLine(w * 0.2f, h * 0.52f, w * 0.38f, h * 0.52f, p); k.drawLine(w * 0.29f, h * 0.43f, w * 0.29f, h * 0.61f, p);
                    p.setStyle(Paint.Style.FILL);
                    k.drawCircle(w * 0.66f, h * 0.46f, w * 0.045f, p); k.drawCircle(w * 0.76f, h * 0.58f, w * 0.045f, p);
                    break;
                case GEAR:
                    p.setStyle(Paint.Style.STROKE);
                    float cx = w / 2, cy = h / 2, r = w * 0.3f;
                    k.drawCircle(cx, cy, r, p); k.drawCircle(cx, cy, w * 0.11f, p);
                    p.setStrokeWidth(3.2f * dp);
                    for (int i = 0; i < 8; i++) {
                        double a = Math.PI / 4 * i;
                        k.drawLine(cx + (float) Math.cos(a) * r, cy + (float) Math.sin(a) * r, cx + (float) Math.cos(a) * w * 0.44f, cy + (float) Math.sin(a) * w * 0.44f, p);
                    }
                    p.setStrokeWidth(1.8f * dp);
                    break;
            }
        }
    }

    /** CoverFlowBackdrop 的两层渐变：四周与底部压暗，字和卡片在任何封面上都看得清。 */
    private final class Shade extends View {
        private final Paint p = new Paint();
        Shade(Context c) { super(c); }
        @Override protected void onDraw(Canvas k) {
            float w = getWidth(), h = getHeight();
            p.setShader(new RadialGradient(w * 0.5f, h * 0.4f, Math.max(1, 900 * dp), new int[]{0, 0x00000000, (BACKGROUND & 0xFFFFFF) | 0xBF000000},
                new float[]{0, 80f / 900, 1}, Shader.TileMode.CLAMP));
            k.drawRect(0, 0, w, h, p);
            p.setShader(new android.graphics.LinearGradient(0, 0, 0, h, new int[]{0x40000000, 0x00000000, (BACKGROUND & 0xFFFFFF) | 0xD9000000},
                new float[]{0, 0.5f, 1}, Shader.TileMode.CLAMP));
            k.drawRect(0, 0, w, h, p);
        }
    }
}
