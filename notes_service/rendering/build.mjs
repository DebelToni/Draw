import {build} from 'esbuild';
import {mkdir, copyFile, cp} from 'node:fs/promises';
await mkdir('bundle', {recursive:true});
await build({entryPoints:['entry.mjs'],bundle:true,platform:'browser',format:'iife',outfile:'bundle/libraries.js',minify:true});
await copyFile('node_modules/katex/dist/katex.min.css','bundle/katex.css');
await cp('node_modules/katex/dist/fonts','bundle/fonts',{recursive:true});
