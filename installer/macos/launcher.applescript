on run
	try
		set wizardPath to POSIX path of (path to resource "run-wizard.sh")
		tell application "Terminal"
			activate
			do script "/bin/sh " & quoted form of wizardPath
		end tell
	on error errorMessage number errorNumber
		if errorNumber is not -128 then
			display dialog "Velron Installer could not open Terminal." & return & return & errorMessage & return & return & "You can also use One-line install at https://velron.codenamemc.kr." buttons {"OK"} default button "OK" with icon caution
		end if
	end try
end run
