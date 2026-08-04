if exists('g:loaded_lazyspeak')
  finish
endif
let g:loaded_lazyspeak = 1

command! LazySpeakStart lua require('lazyspeak').start()
command! LazySpeakStop lua require('lazyspeak').stop()
command! LazySpeakStatus lua vim.notify('[lazyspeak] ' .. require('lazyspeak').status())
command! LazySpeakSidebar lua require('lazyspeak')._ensure_sidebar():toggle()
command! LazySpeakHelp lua local s = require('lazyspeak')._ensure_sidebar() s:open(false) s:toggle_help()
command! LazySpeakDismiss lua require('lazyspeak').dismiss()
command! LazySpeakUndo lua vim.notify('[lazyspeak] undo is no longer available in transcription-only mode', vim.log.levels.WARN)
command! LazySpeakSnapshots lua vim.notify('[lazyspeak] snapshots are no longer available in transcription-only mode', vim.log.levels.WARN)
command! LazySpeakSnapshotsPrune lua vim.notify('[lazyspeak] snapshots are no longer available in transcription-only mode', vim.log.levels.WARN)
command! LazySpeakInstall lua require('lazyspeak.install').run()
