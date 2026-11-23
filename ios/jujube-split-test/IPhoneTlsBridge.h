#pragma once

#import <Foundation/Foundation.h>

BOOL ExportBridgePublicKey(void);
void BridgeAudit(NSString *message);

// Owns the listener for the duration of the split smoke run.
class IPhoneTlsBridge {
public:
    IPhoneTlsBridge() = default;
    ~IPhoneTlsBridge();
    IPhoneTlsBridge(const IPhoneTlsBridge &) = delete;
    IPhoneTlsBridge &operator=(const IPhoneTlsBridge &) = delete;

    bool start();

private:
    struct Listener;
    Listener *listener_ = nullptr;
};
