package main

import (
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"sync"
	"syscall"

	"github.com/creack/pty"
)

type shellSession struct {
	id     string
	runner *Runner
	cmd    *exec.Cmd
	pty    *os.File
	once   sync.Once
}

func (r *Runner) startShellSession(sessionID string, cols, rows int) error {
	r.sessionsMu.Lock()
	if _, exists := r.sessions[sessionID]; exists {
		r.sessionsMu.Unlock()
		return fmt.Errorf("session %s already exists", sessionID)
	}
	r.sessionsMu.Unlock()

	shellPath := defaultShell()
	command := exec.Command(shellPath, "-l")
	command.Env = append(os.Environ(), "TERM=xterm-256color", "COLORTERM=truecolor")

	terminal, err := pty.StartWithSize(command, &pty.Winsize{
		Cols: uint16(max(cols, 80)),
		Rows: uint16(max(rows, 24)),
	})
	if err != nil {
		return fmt.Errorf("start shell: %w", err)
	}

	session := &shellSession{
		id:     sessionID,
		runner: r,
		cmd:    command,
		pty:    terminal,
	}

	r.sessionsMu.Lock()
	r.sessions[sessionID] = session
	r.sessionsMu.Unlock()

	if err := r.writeEnvelope(relayEnvelope{Type: "session.ready", SessionID: sessionID}); err != nil {
		session.close("The shell started but Relay could not confirm readiness.")
		return err
	}

	go session.readLoop()
	go session.waitLoop()
	return nil
}

func (r *Runner) writeInput(sessionID, dataBase64 string) error {
	r.sessionsMu.RLock()
	session, ok := r.sessions[sessionID]
	r.sessionsMu.RUnlock()
	if !ok {
		return fmt.Errorf("session %s not found", sessionID)
	}

	data, err := base64.StdEncoding.DecodeString(dataBase64)
	if err != nil {
		return fmt.Errorf("decode session input: %w", err)
	}

	if _, err := session.pty.Write(data); err != nil {
		return fmt.Errorf("write shell input: %w", err)
	}
	return nil
}

func (r *Runner) resizeSession(sessionID string, cols, rows int) error {
	r.sessionsMu.RLock()
	session, ok := r.sessions[sessionID]
	r.sessionsMu.RUnlock()
	if !ok {
		return fmt.Errorf("session %s not found", sessionID)
	}

	return pty.Setsize(session.pty, &pty.Winsize{
		Cols: uint16(max(cols, 1)),
		Rows: uint16(max(rows, 1)),
	})
}

func (r *Runner) closeSession(sessionID, reason string) {
	r.sessionsMu.RLock()
	session, ok := r.sessions[sessionID]
	r.sessionsMu.RUnlock()
	if ok {
		session.close(reason)
	}
}

func (session *shellSession) readLoop() {
	buffer := make([]byte, 8192)

	for {
		bytesRead, err := session.pty.Read(buffer)
		if bytesRead > 0 {
			if writeErr := session.runner.writeEnvelope(relayEnvelope{
				Type:      "session.output",
				SessionID: session.id,
				Payload: &relayPayload{
					DataBase64: base64.StdEncoding.EncodeToString(buffer[:bytesRead]),
				},
			}); writeErr != nil {
				session.close("Relay lost the connection to the server.")
				return
			}
		}

		if err != nil {
			if err != io.EOF {
				session.runner.logger.Printf("session %s read error: %v", session.id, err)
			}
			return
		}
	}
}

func (session *shellSession) waitLoop() {
	_ = session.cmd.Wait()
	session.close("The remote shell exited.")
}

func (session *shellSession) close(reason string) {
	session.once.Do(func() {
		_ = session.pty.Close()

		if session.cmd.Process != nil {
			_ = session.cmd.Process.Signal(syscall.SIGTERM)
			_ = session.cmd.Process.Kill()
		}

		session.runner.sessionsMu.Lock()
		delete(session.runner.sessions, session.id)
		session.runner.sessionsMu.Unlock()

		_ = session.runner.writeEnvelope(relayEnvelope{
			Type:      "session.closed",
			SessionID: session.id,
			Payload: &relayPayload{
				Reason: reason,
			},
		})
	})
}

func defaultShell() string {
	if shell := os.Getenv("SHELL"); shell != "" {
		return shell
	}

	currentUser, err := user.Current()
	if err == nil && currentUser != nil && currentUser.Username != "" {
		if currentUser.Uid != "" {
			if shell := os.Getenv("SHELL"); shell != "" {
				return shell
			}
		}
	}

	return "/bin/zsh"
}

func max(lhs, rhs int) int {
	if lhs > rhs {
		return lhs
	}
	return rhs
}
