//
// Copyright (c) 2018 Bagel (https://github.com/yagiz/Bagel)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "BagelBrowser.h"
#import "BagelConfiguration.h"

@implementation BagelBrowser {
    NSMutableArray* sockets;
    BOOL didConnectFallback;
}

- (instancetype)initWithConfiguration:(BagelConfiguration*)configuration
{
    self = [super init];

    if (self) {
        self.configuration = configuration;
        didConnectFallback = NO;
        [self startBrowsing];
    }

    return self;
}

- (void)startBrowsing
{
    if (self.services) {
        [self.services removeAllObjects];
    } else {
        self.services = [[NSMutableArray alloc] init];
    }

    if (sockets) {
        [sockets removeAllObjects];
    } else {
        sockets = [[NSMutableArray alloc] init];
    }

    self.serviceBrowser = [[NSNetServiceBrowser alloc] init];
    self.serviceBrowser.delegate = self;

    // Fallback after 5 seconds if nothing found
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.services.count == 0 && !didConnectFallback) {
            NSLog(@"[Bagel] Bonjour discovery failed, falling back to localhost");
            [self connectToHost:@"127.0.0.1" port:43435];
            didConnectFallback = YES;
        }
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.serviceBrowser searchForServicesOfType:self.configuration.netserviceType
                                            inDomain:self.configuration.netserviceDomain];
    });
}

- (void)netServiceBrowser:(NSNetServiceBrowser*)serviceBrowser didFindService:(NSNetService*)service moreComing:(BOOL)moreComing
{
    [self.services addObject:service];

    service.delegate = self;
    [service resolveWithTimeout:30.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser*)serviceBrowser didRemoveService:(NSNetService*)service moreComing:(BOOL)moreComing
{
    [self.services removeObject:service];
}

- (void)netServiceDidResolveAddress:(NSNetService*)service
{
    [self connectWithService:service];
}

- (BOOL)connectWithService:(NSNetService*)service
{
    BOOL isConnected = NO;
    NSMutableArray* addresses = [NSMutableArray arrayWithArray:[service addresses]];

    GCDAsyncSocket* socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];

    while (!isConnected && [addresses count]) {
        NSData* address = [addresses objectAtIndex:0];
        NSError* error = nil;

        if ([socket connectToAddress:address error:&error]) {
            [sockets addObject:socket];
            isConnected = YES;
        } else if (error) {
            NSLog(@"[Bagel] Connect error: %@", error.localizedDescription);
        }

        [addresses removeObjectAtIndex:0];
    }

    return isConnected;
}


- (void)connectToHost:(NSString *)host port:(UInt16)port
{
    NSError *error = nil;
    GCDAsyncSocket *socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];

    if ([socket connectToHost:host onPort:port error:&error]) {
        NSLog(@"[Bagel] Connected to fallback host %@:%d", host, port);
        [sockets addObject:socket];
    } else {
        NSLog(@"[Bagel] Fallback connection failed: %@", error.localizedDescription);
    }
}

- (void)socket:(GCDAsyncSocket*)socket didConnectToHost:(NSString*)host port:(UInt16)port
{
    [socket readDataToLength:sizeof(uint64_t) withTimeout:-1.0 tag:0];
}

- (void)sendPacket:(BagelRequestPacket*)packet
{
    NSError *error;
    NSData* packetData = [NSJSONSerialization dataWithJSONObject:[packet toJSON] options:0 error:&error];

    if (error) {
        NSLog(@"Bagel -> Error: %@", error.localizedDescription);
        return;
    }

    if (packetData) {
        NSMutableData* buffer = [[NSMutableData alloc] init];
        uint64_t headerLength = [packetData length];
        [buffer appendBytes:&headerLength length:sizeof(uint64_t)];
        [buffer appendBytes:[packetData bytes] length:[packetData length]];

        for (GCDAsyncSocket* socket in sockets) {
            [socket writeData:buffer withTimeout:-1.0 tag:0];
        }
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket*)socket withError:(NSError*)error
{
    [socket setDelegate:nil];
    [sockets removeObject:socket];
}

- (void)netServiceBrowser:(NSNetServiceBrowser*)aBrowser didNotSearch:(NSDictionary*)userInfo
{
    [self resetAndBrowse];
}

- (void)resetAndBrowse
{
    [self.serviceBrowser stop];
    self.serviceBrowser = nil;

    [self startBrowsing];
}

@end
