// WHClient.m
// 
// Copyright (c) 2013 Rui D Lopes
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

#import <CocoaLumberjack/DDTTYLogger.h>
#import <CocoaLumberjack/DDASLLogger.h>
#import "WHClient.h"
#import "WHHTMLRequestOperation.h"
#import "NSObject+GCD.h"
#import "NSObject+Runtime.h"
#import "NSError+WebHere.h"
#import "WHObjectFactory.h"

NSTimeInterval const kWHClientDefaultTimeoutInterval = 2;
NSInteger const kWHClientDefaultNumberOfRetries = 1;


@interface WHClient ()

@property(nonatomic, strong) AFHTTPClient *httpClient;

- (id <WHObject>)mapHTMLPage:(HTMLDocument *)page
                       atURL:(NSURL *)URL
                 fromRequest:(WHRequest *)request
            usingTargetClass:(Class<WHObject>)targetClass
                       error:(NSError **)error;
@end

@implementation WHClient

static WHClient *sharedClient = nil;

+ (void) initialize {
    [DDLog addLogger:[DDASLLogger sharedInstance]];
    [DDLog addLogger:[DDTTYLogger sharedInstance]];
}

+ (instancetype)sharedClient {
    return sharedClient;
}

+ (void)setSharedClient:(WHClient *)client {
    if (client != sharedClient) {
        sharedClient = client;
        DDLogVerbose(@"Shared client:%@", sharedClient);
    }
}

+ (instancetype)clientWithBaseURL:(NSURL *)baseURL {
    return [[WHClient alloc] initWithBaseURL:baseURL];
}

- (instancetype)initWithBaseURL:(NSURL *)baseURL {
    NSParameterAssert(baseURL);
    self = [super init];
    if (self) {
        _httpClient = [AFHTTPClient clientWithBaseURL:baseURL];
        [_httpClient registerHTTPOperationClass:[WHHTMLRequestOperation class]];
        _numberOfRetries = kWHClientDefaultNumberOfRetries;
        _timeoutInterval = kWHClientDefaultTimeoutInterval;
        DDLogInfo(@"Initialized:%@", self);
    }
    if (self && !sharedClient) {sharedClient = self;}
    return self;
}

- (NSURL *)baseURL {
    return self.httpClient.baseURL;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"[%@ - %@ | retries %ld time(s) | timeout after %f secs]",
            [super description], self.baseURL, (unsigned long) self.numberOfRetries, self.timeoutInterval];
}

- (void)setAuthorizationUserName:(NSString *)username password:(NSString *)password {
    [self.httpClient clearAuthorizationHeader];
    [self.httpClient setAuthorizationHeaderWithUsername:username password:password];
    DDLogVerbose(@"Authorization credentials set for %@", username);
}

- (void)setAuthorizationToken:(NSString *)token {
    [self.httpClient clearAuthorizationHeader];
    [self.httpClient setAuthorizationHeaderWithToken:token];
    DDLogVerbose(@"Authorization token set");
}

- (void)send:(WHRequest *)request success:(WHLoadSuccessfulBlock)success failure:(WHLoadFailureBlock)failure {
    NSParameterAssert(request);
    DDLogInfo(@"Will send request:%@", request);
    NSDictionary *queryParameters = request.queryParameters.count ? request.queryParameters : nil;
    
    // Make sure the encoding will correspond to the request encoding
    self.httpClient.stringEncoding = request.encoding;
    
    // Build the request
    NSMutableURLRequest *URLRequest = [self.httpClient requestWithMethod:request.HTTPMethod path:request.path parameters:queryParameters];
    [URLRequest setTimeoutInterval:self.timeoutInterval];
    
    WHHTMLRequestOperation *operation =
    [WHHTMLRequestOperation
     HTMLRequestOperationWithRequest:URLRequest
     success:^(NSURLRequest *HTTPRequest, NSHTTPURLResponse *HTTPResponse, HTMLDocument *page) {
         DDLogVerbose(@"HTTP Client did receive response from request:%@", request);
         request.retryCount = 0;
         DDLogVerbose(@"Retry count reset for request:%@", request);
         
         [self performAsynchronous:^{
             
             // List possible targets
             Class<WHObject> targetClass = request.targetClass;
             NSMutableArray *alternativeTargetClasses = [request.alternativeTargetClasses mutableCopy];
             NSError *error = nil;
             BOOL stopMapping = NO;
             id <WHObject> object = nil;
             
             DDLogVerbose(@"Will try mapping HTML page %@ / from request %@ / using target class %@ / or alternative classes %@", page, request, targetClass, alternativeTargetClasses);
             while (!stopMapping) {
                 DDLogVerbose(@"Will try mapping HTML page %@ / from request %@ / using target class %@", page, request, targetClass);
                 object = [self mapHTMLPage:page atURL:HTTPResponse.URL fromRequest:request usingTargetClass:targetClass error:&error];
                 stopMapping = !error || !alternativeTargetClasses.count;
                 
                 if (alternativeTargetClasses.count) {
                     targetClass = alternativeTargetClasses[0];
                     [alternativeTargetClasses removeObjectAtIndex:0];
                     error = nil;
                 }
             }
             
             if (error) {
                 DDLogError(@"Failed mapping HTML page %@ / from request %@ / error:%@", page, request, error);
                 failure(request,error);
                 DDLogVerbose(@"Called failure block %@ / request %@ / error %@", failure, request, error);
             } else {
                 DDLogVerbose(@"Successfully mapped HTML page %@ / from request %@ / object:%@", page, request, object);
                 success(request,object);
                 DDLogVerbose(@"Called success block %@ / request %@ / object %@", success, request, object);
             }
             
         }];
     }
     failure:^(NSURLRequest *HTTPRequest, NSHTTPURLResponse *HTTPResponse, NSError *error, HTMLDocument *page) {
         
         if (request.retryCount < self.numberOfRetries) {
             // Resend
             request.retryCount ++;
             DDLogVerbose(@"HTTP request tried %ld times < %ld trials -> Retry sending %@",
                      (unsigned long) request.retryCount, (unsigned long) self.numberOfRetries, request);
             [self send:request success:success failure:failure];
         } else {
             // Report the error
             DDLogVerbose(@"HTTP request sent %ld times (limit = %ld) -> Failing on HTTP request %@ from initial request %@",
                      (unsigned long) request.retryCount, (unsigned long) self.numberOfRetries, HTTPRequest, request);
             failure(request, error);
         }
     }];
    
    DDLogVerbose(@"Request %@ will be sent using operation:%@", request, operation);
    [self.httpClient enqueueHTTPRequestOperation:operation];
}

- (id <WHObject>)mapHTMLPage:(HTMLDocument *)page
                       atURL:(NSURL *)URL
                 fromRequest:(WHRequest *)request
            usingTargetClass:(Class<WHObject>)targetClass
                       error:(NSError **)error
{
    
    // Create an object stub from factory
    id <WHObject> object = [WHObjectFactory createObjectWithClass:targetClass error:error];
    if (*error) {
        DDLogError(@"Failed to create object with class %@ / error:%@", targetClass, *error);
    } else {
        DDLogVerbose(@"Created object %@ -> Building object", object);
        
        // Set the URL
        object.URL = URL;
        
        // Build object from HTML page
        BOOL canBuild = [object respondsToSelector:@selector(matches:fromRequest:)] ? [object matches:page fromRequest:request] : YES;
        if (canBuild) {
            [object buildWithHTMLPage:page fromRequest:request error:error];
        } else {
            *error = [NSError errorWithCode:WHErrorNoMatchingClassFoundForMapping];
        }
        
        if (*error) {
            DDLogError(@"Failed to build object %@ from HTML page %@ / error:%@", object, page, *error);
        } else {
            DDLogVerbose(@"Built object %@ from HTML page %@ received from request %@ -> Calling success block", object, page, request);
        }
    }
    return object;
}

@end
