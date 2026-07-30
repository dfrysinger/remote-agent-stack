on run argv
	if (count of argv) is not 2 then error "expected recipient and message"
	set recipientHandle to item 1 of argv
	set messageBody to item 2 of argv
	tell application "Messages"
		set imessageService to first service whose service type is iMessage
		set recipientBuddy to buddy recipientHandle of imessageService
		send messageBody to recipientBuddy
	end tell
end run
