# -*- coding: utf-8 -*-
#
# dasVulkan documentation build configuration file.
#
# Vendored from daslang/doc/source/conf.py via dasImgui — LaTeX/rinohtype/
# manpage/texinfo build paths trimmed (HTML-only Pages deploy). Diff and
# reconcile annually against daslang upstream when the daslang Sphinx domain
# evolves.

import sys
import os
import time

# Make the vendored `daslang` Sphinx domain importable.
sys.path.insert(0, os.path.abspath('.'))

extensions = ['daslang', 'tutorial_video', 'sphinx.ext.intersphinx']

# Tutorial recordings (.mp4) live with their self-contained tutorial under
# <repo>/tutorials/<name>/ (the tracked source). Copy them into _static/tutorials/
# at build time so the `.. video::` directive can serve them without committing the
# binary twice; the copies are gitignored. Runs at conf load, before the build.
import shutil as _shutil
import glob as _glob
_conf_dir = os.path.abspath(os.path.dirname(__file__))
_repo_root = os.path.abspath(os.path.join(_conf_dir, '..', '..'))
_video_dst = os.path.join(_conf_dir, '_static', 'tutorials')
os.makedirs(_video_dst, exist_ok=True)
_seen_videos = {}
for _mp4 in _glob.glob(os.path.join(_repo_root, 'tutorials', '**', '*.mp4'), recursive=True):
    _base = os.path.basename(_mp4)
    # The `.. video::` directive serves by basename, so two tutorials sharing an
    # mp4 name would silently overwrite each other -> the wrong video embedded.
    # Fail the build loudly instead; each tutorial's recording must be uniquely named.
    if _base in _seen_videos:
        raise RuntimeError(
            "tutorial video basename collision: %r and %r both map to "
            "_static/tutorials/%s -- give each tutorial's mp4 a unique name"
            % (_seen_videos[_base], _mp4, _base))
    _seen_videos[_base] = _mp4
    _shutil.copy2(_mp4, os.path.join(_video_dst, _base))

# Resolve cross-refs to daslang core (VkResult, JsonValue, etc.) against the
# published daslang documentation. Sphinx fetches objects.inv at build time.
intersphinx_mapping = {
    'daslang': ('https://daslang.io/doc/', None),
}
intersphinx_disabled_reftypes = []

templates_path = ['_templates']

suppress_warnings = ['toctree.not_included']

source_suffix = '.rst'

master_doc = 'index'

project = u'dasVulkan documentation'
copyright = '2026-%s, Gaijin Entertainment' % time.strftime('%Y')
author = u'Boris Batkin'

version = u'1.0'
release = u'1.0'

language = 'en'

# Intermediate files used by vulkan2rst — not standalone documentation pages.
exclude_patterns = ['stdlib/generated/detail', 'stdlib/handmade']

pygments_style = 'sphinx'
highlight_language = 'none'

todo_include_todos = False

# -- Options for HTML output ----------------------------------------------

html_theme = 'sphinx_rtd_theme'
html_theme_options = {
    'style_nav_header_background': '#0d0c0a',
    'collapse_navigation': False,
    'sticky_navigation': True,
    'navigation_depth': 4,
    'titles_only': False,
}
html_logo = '_static/forge-logo.svg'
html_favicon = 'daslang-favicon.svg'
html_static_path = ['_static']
# sphinx_rtd_theme reads this and adds an "Edit on GitHub" link to every page header.
html_context = {
    'display_github': True,
    'github_user': 'borisbat',
    'github_repo': 'dasVulkan',
    'github_version': 'master',
    'conf_py_path': '/doc/source/',
}
# Forge dark retoken — matches daslang.io/doc/ visually. Vendored from
# daslang's doc/source/_static/custom.css; reconcile against upstream when
# the daslang docs theme evolves.
html_css_files = ['custom.css', 'custom-patch.css']

html_js_files = ['sidebar.js']

htmlhelp_basename = 'dasvulkan_doc'
