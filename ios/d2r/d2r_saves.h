// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors

#import <Foundation/Foundation.h>

extern NSString *const S2AD2RSaveLocation;

NSURL *S2AD2ROpenSave(NSURL *documents, NSURL *state, NSError **error);
NSArray<NSString *> *S2AD2RCharacterNames(NSURL *save, NSError **error);
BOOL S2AD2RImportCharacter(NSURL *character, NSURL *save, NSError **error);
