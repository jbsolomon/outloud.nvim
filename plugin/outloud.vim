if exists('g:loaded_outloud')
  finish
endif
let g:loaded_outloud = 1

command! OutloudStart lua require('outloud').start()
command! OutloudStop lua require('outloud').stop()
command! OutloudStatus lua vim.notify('[outloud] ' .. require('outloud').status())
command! OutloudSidebar lua require('outloud')._ensure_sidebar():toggle()
command! OutloudHelp lua local s = require('outloud')._ensure_sidebar() s:open(false) s:toggle_help()
command! OutloudDismiss lua require('outloud').dismiss()
command! OutloudUndo lua vim.notify('[outloud] undo is no longer available in transcription-only mode', vim.log.levels.WARN)
command! OutloudSnapshots lua vim.notify('[outloud] snapshots are no longer available in transcription-only mode', vim.log.levels.WARN)
command! OutloudSnapshotsPrune lua vim.notify('[outloud] snapshots are no longer available in transcription-only mode', vim.log.levels.WARN)
command! OutloudInstall lua require('outloud.install').run()
command! OutloudDevices lua require('outloud').list_devices()
command! VoiceConfirmBuf lua require('outloud').confirm_accumulator()
command! VoiceCancelBuf lua require('outloud').cancel_accumulator()
command! VoiceClearBuf lua require('outloud').clear_accumulator()
command! OutloudScratchpad lua require('outloud').toggle_scratchpad()
