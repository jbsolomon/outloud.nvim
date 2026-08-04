if exists('g:loaded_outloud')
  finish
endif
let g:loaded_outloud = 1

command! OutLoudStart lua require('outloud').start()
command! OutLoudStop lua require('outloud').stop()
command! OutLoudStatus lua vim.notify('[outloud] ' .. require('outloud').status())
command! OutLoudSidebar lua require('outloud')._ensure_sidebar():toggle()
command! OutLoudHelp lua local s = require('outloud')._ensure_sidebar() s:open(false) s:toggle_help()
command! OutLoudDismiss lua require('outloud').dismiss()
command! OutLoudUndo lua vim.notify('[outloud] undo is no longer available in transcription-only mode', vim.log.levels.WARN)
command! OutLoudSnapshots lua vim.notify('[outloud] snapshots are no longer available in transcription-only mode', vim.log.levels.WARN)
command! OutLoudSnapshotsPrune lua vim.notify('[outloud] snapshots are no longer available in transcription-only mode', vim.log.levels.WARN)
command! OutLoudInstall lua require('outloud.install').run()
command! VoiceConfirmBuf lua require('outloud').confirm_accumulator()
command! VoiceCancelBuf lua require('outloud').cancel_accumulator()
command! VoiceClearBuf lua require('outloud').clear_accumulator()
