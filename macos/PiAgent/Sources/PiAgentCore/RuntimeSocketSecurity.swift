import Foundation

#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Connection-time checks for the App-managed Runtime socket. Development and
/// explicitly supplied sockets intentionally remain permissive for backwards
/// compatibility; a bundled App must not trust a path merely because it has
/// the expected name.
public enum RuntimeSocketSecurity: Sendable {
	case permissive
	case bundled

	public func validate(socketPath: String) throws {
		guard case .bundled = self else { return }
		let expectedOwner = getuid()
		let socket = try metadata(for: socketPath, label: "Runtime socket")
		guard fileType(of: socket) == mode_t(S_IFSOCK) else {
			throw unsafeSocket("is not a Unix domain socket", socketPath)
		}
		guard socket.st_uid == expectedOwner else {
			throw unsafeSocket("is not owned by the current user", socketPath)
		}
		guard permissions(of: socket) == 0o600 else {
			throw unsafeSocket("must have mode 0600", socketPath)
		}

		let parentPath = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
		let parent = try metadata(for: parentPath, label: "Runtime socket directory")
		guard fileType(of: parent) == mode_t(S_IFDIR) else {
			throw unsafeSocket("parent is not a directory", parentPath)
		}
		guard parent.st_uid == expectedOwner else {
			throw unsafeSocket("parent is not owned by the current user", parentPath)
		}
		guard permissions(of: parent) == 0o700 else {
			throw unsafeSocket("parent must have mode 0700", parentPath)
		}
	}

	public func validateConnectedPeer(descriptor: Int32) throws {
		guard case .bundled = self else { return }
		#if os(macOS)
		var uid: uid_t = 0
		var gid: gid_t = 0
		guard getpeereid(descriptor, &uid, &gid) == 0 else {
			throw RuntimeClientError.connectionFailed("Could not verify bundled Runtime socket peer: \(String(cString: strerror(errno)))")
		}
		guard uid == getuid() else {
			throw RuntimeClientError.connectionFailed("Refusing bundled Runtime socket peer owned by another user")
		}
		#endif
	}

	private func metadata(for path: String, label: String) throws -> stat {
		var value = stat()
		guard lstat(path, &value) == 0 else {
			throw RuntimeClientError.connectionFailed("Could not inspect \(label): \(String(cString: strerror(errno)))")
		}
		return value
	}

	private func fileType(of metadata: stat) -> mode_t {
		metadata.st_mode & mode_t(S_IFMT)
	}

	private func permissions(of metadata: stat) -> mode_t {
		metadata.st_mode & 0o777
	}

	private func unsafeSocket(_ message: String, _ path: String) -> RuntimeClientError {
		.connectionFailed("Refusing unsafe bundled Runtime socket: \(path) \(message)")
	}
}
