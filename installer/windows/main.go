// Velron Installer opens the existing PowerShell installation wizard.
// It contains no installation, configuration, or update logic of its own.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

const installCommand = "irm https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.ps1 | iex"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--print-command" {
		fmt.Println(installCommand)
		return
	}
	if len(os.Args) > 1 {
		fmt.Println("Velron Installer: open this program to run the interactive installation wizard.")
		fmt.Println("--print-command prints the command without downloading or installing anything.")
		return
	}

	fmt.Println("Velron Installer")
	fmt.Println("Starting the official interactive installation wizard...")
	fmt.Println()

	status := 0
	if err := runWizard(); err != nil {
		status = 1
		if exit, ok := err.(*exec.ExitError); ok && exit.ExitCode() > 0 {
			status = exit.ExitCode()
		}
		fmt.Fprintln(os.Stderr, "\nThe installer could not finish:", err)
		fmt.Fprintln(os.Stderr, "Review the error above and try again, or use One-line install on https://velron.codenamemc.kr.")
	} else {
		fmt.Println("\nThe installation wizard has closed.")
	}
	// A double-clicked console must stay open so errors and next steps remain visible.
	fmt.Print("Press Enter to close...")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
	os.Exit(status)
}

func runWizard() error {
	if runtime.GOOS != "windows" {
		return fmt.Errorf("this launcher is for Windows")
	}
	systemRoot := os.Getenv("SystemRoot")
	if systemRoot == "" {
		return fmt.Errorf("the Windows SystemRoot directory is unavailable")
	}
	// Use the system PowerShell, never an executable from the download directory.
	powershell := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	command := exec.Command(powershell, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; "+installCommand)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}
