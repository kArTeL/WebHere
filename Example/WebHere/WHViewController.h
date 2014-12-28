//
//  WHViewController.h
//  WebHere
//
//  Created by Rui Lopes on 12/28/2014.
//  Copyright (c) 2014 Rui Lopes. All rights reserved.
//

#import <UIKit/UIKit.h>

@class WHSearchRequest;
@class WHSearchResponse;

@interface WHViewController : UIViewController

@property(strong, nonatomic) WHSearchRequest *searchRequest;
@property(strong, nonatomic) WHSearchResponse *searchResponse;

@end
