package app.railwayatlas.android;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Message;
import android.util.Base64;
import android.view.View;
import android.webkit.*;
import android.widget.FrameLayout;
import android.widget.Toast;
import androidx.webkit.WebViewAssetLoader;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;
import java.io.ByteArrayInputStream;
import java.io.OutputStream;
import java.util.Collections;
import org.json.JSONObject;

public final class AtlasActivity extends Activity {
    private static final String ORIGIN = "https://appassets.androidplatform.net";
    private static final String START = ORIGIN + "/atlas/index.html";
    private static final int IMPORT = 1, EXPORT = 2;
    private FrameLayout frame;
    private WebView main, popup;
    private WebViewAssetLoader assets;
    private ValueCallback<Uri[]> chooser;
    private byte[] exportBytes;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        assets = new WebViewAssetLoader.Builder().addPathHandler("/atlas/",
                new WebViewAssetLoader.AssetsPathHandler(this)).build();
        frame = new FrameLayout(this);
        frame.setOnApplyWindowInsetsListener((v, insets) -> {
            v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(frame);
        main = makeView();
        if (saved == null || main.restoreState(saved) == null) main.loadUrl(START);
    }

    private WebView makeView() {
        WebView view = new WebView(this);
        frame.addView(view, -1, -1);
        view.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        view.setContentDescription("铁道漫游地图");
        WebSettings s = view.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setSupportMultipleWindows(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        view.setWebViewClient(new WebViewClient() {
            @Override public WebResourceResponse shouldInterceptRequest(WebView v, WebResourceRequest req) {
                Uri uri = req.getUrl();
                if (!WebViewAssetLoader.DEFAULT_DOMAIN.equals(uri.getHost())) return null;
                WebResourceResponse resource = assets.shouldInterceptRequest(uri);
                if (resource == null || resource.getData() == null)
                    return new WebResourceResponse("text/plain","utf-8",404,"Not Found",
                            Collections.emptyMap(),new ByteArrayInputStream(new byte[0]));
                String path = uri.getPath();
                if (path != null && path.endsWith(".mjs")) resource.setMimeType("text/javascript");
                if (path != null && path.endsWith(".wasm")) resource.setMimeType("application/wasm");
                return resource;
            }
            @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                Uri url = req.getUrl();
                if ("https".equals(url.getScheme()) && WebViewAssetLoader.DEFAULT_DOMAIN.equals(url.getHost())
                        && "/atlas/index.html".equals(url.getPath())) return false;
                if (req.isForMainFrame() && ("https".equals(url.getScheme()) || "http".equals(url.getScheme()))) {
                    try { startActivity(new Intent(Intent.ACTION_VIEW,url)); }
                    catch (ActivityNotFoundException e) { notice("手机上没有可打开链接的浏览器。"); }
                    if (v == popup && (v.getUrl() == null || "about:blank".equals(v.getUrl()))) v.post(() -> closePopup(v));
                }
                return true;
            }
        });
        view.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> callback, FileChooserParams options) {
                if (chooser != null) chooser.onReceiveValue(null);
                chooser = callback;
                Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE);
                try { startActivityForResult(pick,IMPORT); }
                catch (ActivityNotFoundException e) { chooser = null; callback.onReceiveValue(null); notice("无法打开系统文件选择器。"); }
                return true;
            }
            @Override public boolean onCreateWindow(WebView v, boolean dialog, boolean userGesture, Message result) {
                if (!userGesture || popup != null) return false;
                popup = makeView();
                ((WebView.WebViewTransport)result.obj).setWebView(popup);
                result.sendToTarget();
                return true;
            }
            @Override public void onCloseWindow(WebView v) { closePopup(v); }
        });
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(view, "RailwayFileExport", Collections.singleton(ORIGIN),
                    (v, msg, origin, top, reply) -> { if (top) requestExport(msg.getData()); });
        }
        return view;
    }

    private void closePopup(WebView v) {
        if (v != popup || v == null) return;
        frame.removeView(v); v.destroy(); popup = null;
    }
    private void requestExport(String message) {
        if (message == null || message.length() > 24 * 1024 * 1024 || exportBytes != null) {
            notice("请先完成当前保存，单次导出上限为 18 MB。"); return;
        }
        try {
            JSONObject args = new JSONObject(message);
            String name = args.getString("name");
            if (!name.matches("[\\p{L}\\p{N} ._-]{1,120}\\.(json|csv|png)")) throw new IllegalArgumentException();
            String type = name.endsWith(".png") ? "image/png" : name.endsWith(".csv") ? "text/csv" : "application/json";
            exportBytes = Base64.decode(args.getString("data"),Base64.DEFAULT);
            startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).setType(type)
                    .addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE,name),EXPORT);
        } catch (Exception e) { exportBytes = null; notice("无法保存这份文件。"); }
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request,result,data);
        Uri uri = result == RESULT_OK && data != null ? data.getData() : null;
        if (request == IMPORT && chooser != null) {
            chooser.onReceiveValue(uri == null ? null : new Uri[]{uri}); chooser = null;
        }
        if (request == EXPORT) {
            byte[] bytes = exportBytes; exportBytes = null;
            if (bytes != null && uri != null) new Thread(() -> {
                try (OutputStream stream = getContentResolver().openOutputStream(uri,"wt")) { stream.write(bytes); }
                catch (Exception e) { runOnUiThread(() -> notice("文件写入失败。")); }
            }).start();
        }
    }
    private void notice(String text) { Toast.makeText(this,text,Toast.LENGTH_LONG).show(); }
    @Override public void onBackPressed() {
        if (popup != null) closePopup(popup);
        else if (main.canGoBack()) main.goBack();
        else main.evaluateJavascript("typeof closeTopMapPanel === 'function' && closeTopMapPanel()",
                result -> { if (!"true".equals(result)) finish(); });
    }
    @Override protected void onSaveInstanceState(Bundle out) { super.onSaveInstanceState(out); main.saveState(out); }
    @Override protected void onDestroy() {
        if (popup != null) closePopup(popup);
        frame.removeView(main); main.destroy(); super.onDestroy();
    }
}
