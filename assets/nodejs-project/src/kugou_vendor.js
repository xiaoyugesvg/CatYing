// 自动生成 —— 不要手改。
//
// 为什么需要它：`esbuild` 只静态解析**字面量** import/require。桥接层原来用
// `require2(变量)` 动态加载 vendor 与依赖，esbuild 看不见 → vendor 既没进
// bundle、也没随 App 分发（设备上只有 dist/）→ 运行时 `Cannot find module`。
//
// 这里用字面量 import 全部列出：Node ESM 直跑可原生 import CJS ✓，
// esbuild 打包能静态 inline ✓ —— 两种模式都对。

import m_util_util_js from '../vendor/kugou/util/util.js';
import m_util_crypto_js from '../vendor/kugou/util/crypto.js';
import m_util_request_js from '../vendor/kugou/util/request.js';
import m_util_generate_simulate_js from '../vendor/kugou/util/generate_simulate.js';
import m_module_search_js from '../vendor/kugou/module/search.js';
import m_module_search_complex_js from '../vendor/kugou/module/search_complex.js';
import m_module_register_dev_js from '../vendor/kugou/module/register_dev.js';
import m_module_song_url_js from '../vendor/kugou/module/song_url.js';
import m_module_search_lyric_js from '../vendor/kugou/module/search_lyric.js';
import m_module_lyric_js from '../vendor/kugou/module/lyric.js';
import m_module_rank_list_js from '../vendor/kugou/module/rank_list.js';
import m_module_rank_audio_js from '../vendor/kugou/module/rank_audio.js';
import m_module_rank_info_js from '../vendor/kugou/module/rank_info.js';
import m_module_top_playlist_js from '../vendor/kugou/module/top_playlist.js';
import m_module_playlist_detail_js from '../vendor/kugou/module/playlist_detail.js';
import m_module_playlist_track_all_js from '../vendor/kugou/module/playlist_track_all.js';
import m_module_search_hot_js from '../vendor/kugou/module/search_hot.js';
import m_module_top_song_js from '../vendor/kugou/module/top_song.js';
import d_axios from 'axios';
import d_crypto_js from 'crypto-js';
import d_node_forge from 'node-forge';
import d_big_integer from 'big-integer';
import d_pako from 'pako';

export const KUGOU_VENDOR = {
    'util/util.js': m_util_util_js,
    'util/crypto.js': m_util_crypto_js,
    'util/request.js': m_util_request_js,
    'util/generate_simulate.js': m_util_generate_simulate_js,
    'module/search.js': m_module_search_js,
    'module/search_complex.js': m_module_search_complex_js,
    'module/register_dev.js': m_module_register_dev_js,
    'module/song_url.js': m_module_song_url_js,
    'module/search_lyric.js': m_module_search_lyric_js,
    'module/lyric.js': m_module_lyric_js,
    'module/rank_list.js': m_module_rank_list_js,
    'module/rank_audio.js': m_module_rank_audio_js,
    'module/rank_info.js': m_module_rank_info_js,
    'module/top_playlist.js': m_module_top_playlist_js,
    'module/playlist_detail.js': m_module_playlist_detail_js,
    'module/playlist_track_all.js': m_module_playlist_track_all_js,
    'module/search_hot.js': m_module_search_hot_js,
    'module/top_song.js': m_module_top_song_js,
};

export const KUGOU_DEPS = {
    'axios': d_axios,
    'crypto-js': d_crypto_js,
    'node-forge': d_node_forge,
    'big-integer': d_big_integer,
    'pako': d_pako,
};

