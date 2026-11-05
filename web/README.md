# Calendar Alerts site

`index.html` is the plugin's home page, with its pictures in `images/` (copies of the ones in `docs/images`, the plugin icon as `icon.png`, and `og-image.png`, the 1200 × 627 link preview). `privacy/index.html` is the privacy page. The favicons are the plugin icon, resized.

## Publishing with GitHub Pages

`.github/workflows/pages.yml` deploys this folder whenever something in it changes on `main`, or when run by hand from the Actions tab. Set **Settings → Pages → Source** to **GitHub Actions** once.

The Download buttons point at `releases/latest/download/com.joeangell.calendar-alerts.streamDeckPlugin`, so a new release needs no change here as long as the file keeps that name.

To try the page locally, serve this folder (for example `python3 -m http.server` in `web/`) and open `http://localhost:8000/`.
