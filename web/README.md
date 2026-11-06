# Calendar Alerts site

The site is published at https://sdcalendaralerts.tmproductions.com/. `index.html` is the plugin's home page, with its pictures in `images/` (copies of the ones in `docs/images`, the thirty moon phases from `Images/` in `images/moon/` so the page can show tonight's moon the way the plugin works it out, the plugin icon as `icon.png`, and `og-image.png`, the 1200 × 627 link preview). `privacy/index.html` is the privacy page. The favicons are the plugin icon, resized.

## Publishing with GitHub Pages

`.github/workflows/pages.yml` deploys this folder whenever something in it changes on `main`, or when run by hand from the Actions tab. Set **Settings → Pages → Source** to **GitHub Actions** once.

The Download buttons point at `releases/latest/download/com.joeangell.calendar-alerts.streamDeckPlugin`, so a new release needs no change here as long as the file keeps that name.

To try the page locally, serve this folder (for example `python3 -m http.server` in `web/`) and open `http://localhost:8000/`.

The custom domain is set in **Settings → Pages → Custom domain** (with a CNAME record for `sdcalendaralerts.tmproductions.com` pointing to `jangellx.github.io`), so no `CNAME` file is needed here.
