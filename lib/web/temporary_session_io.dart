/// Only the web has temporary sessions (see temporary_session_web.dart).
bool get temporaryMarked => false;

void markTemporary() {}

void endTemporary() {}

Future<void> wipeEndedTemporarySession() async {}

void warnBeforeLeaving(bool on) {}

void reloadPage() {}

void setSignedInFlag(bool signedIn) {}
