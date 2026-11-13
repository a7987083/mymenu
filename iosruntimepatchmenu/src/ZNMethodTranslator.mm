#import "ZNMethodTranslator.h"
#import "ZNMethodDictionary.generated.h"

static NSDictionary<NSString *,NSString *> *ZNMP4Dictionary(void) {
    static NSDictionary<NSString *,NSString *> *dictionary;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data=[NSData dataWithBytes:kZNMethodDictionaryJSON length:sizeof(kZNMethodDictionaryJSON)-1];
        id parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        dictionary=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    });
    return dictionary;
}

// Split underscores, digits/case transitions and acronym boundaries without
// altering the original method name. Does not query IL2CPP or network APIs.
static NSArray<NSString *> *ZNMP4LexicalChunks(NSString *name) {
    NSMutableArray<NSString *> *chunks=[NSMutableArray array];
    NSMutableString *part=[NSMutableString string];
    for(NSUInteger i=0;i<name.length;i++) {
        unichar c=[name characterAtIndex:i];
        BOOL letter=(c>='a'&&c<='z')||(c>='A'&&c<='Z');
        if(!letter) {
            if(part.length){[chunks addObject:part.lowercaseString];[part setString:@""];}
            continue;
        }
        if(part.length) {
            unichar previous=[name characterAtIndex:i-1];
            unichar next=(i+1<name.length)?[name characterAtIndex:i+1]:0;
            BOOL lowerToUpper=(previous>='a'&&previous<='z')&&(c>='A'&&c<='Z');
            BOOL acronymBoundary=(previous>='A'&&previous<='Z')&&(c>='A'&&c<='Z')&&(next>='a'&&next<='z');
            if(lowerToUpper||acronymBoundary) {
                [chunks addObject:part.lowercaseString];[part setString:@""];
            }
        }
        [part appendFormat:@"%C",c];
    }
    if(part.length)[chunks addObject:part.lowercaseString];
    return chunks;
}

// DP minimizes token count, giving the longest dictionary words priority.
// Never split an already-known whole word such as "address" into "add"+... .
static NSArray<NSString *> *ZNMP4Segment(NSString *chunk,NSDictionary *dict) {
    if(dict[chunk])return @[chunk];
    NSUInteger len=chunk.length;
    if(!len||len>96)return nil;
    NSMutableArray *best=[NSMutableArray arrayWithCapacity:len+1];
    for(NSUInteger i=0;i<=len;i++)[best addObject:NSNull.null];
    best[len]=@[];
    for(NSInteger i=(NSInteger)len-1;i>=0;i--) {
        NSArray *choice=nil;
        for(NSUInteger j=(NSUInteger)i+2;j<=MIN(len,(NSUInteger)i+28);j++) {
            NSString *word=[chunk substringWithRange:NSMakeRange((NSUInteger)i,j-(NSUInteger)i)];
            if(!dict[word]||best[j]==NSNull.null)continue;
            NSMutableArray *candidate=[NSMutableArray arrayWithObject:word];
            [candidate addObjectsFromArray:best[j]];
            if(!choice||candidate.count<choice.count)choice=candidate;
        }
        if(choice)best[(NSUInteger)i]=choice;
    }
    return best[0]==NSNull.null?nil:best[0];
}

static NSString *ZNMP4Phrase(NSArray<NSString *> *tokens,NSDictionary<NSString *,NSString *> *dictionary) {
    if(!tokens.count)return nil;
    NSMutableArray<NSString *> *translated=[NSMutableArray arrayWithCapacity:tokens.count];
    for(NSString *token in tokens) {
        NSString *word=dictionary[token];
        if(!word.length)return nil;
        [translated addObject:word];
    }
    NSString *first=tokens.firstObject;
    // Multi-resource "AddCoinGem" means "add coin and gem" only as a
    // naming gloss, not verified behavior. Keep the source name visible.
    NSSet *addVerbs=[NSSet setWithArray:@[@"add",@"remove",@"delete",@"grant",@"give"]];
    if(tokens.count==3&&[addVerbs containsObject:first]) {
        return [NSString stringWithFormat:@"%@%@和%@",translated[0],translated[1],translated[2]];
    }
    NSMutableString *out=[NSMutableString string];
    for(NSUInteger i=0;i<translated.count;i++) {
        NSString *piece=translated[i];
        BOOL abbreviation=([piece isEqualToString:piece.uppercaseString]
                           &&[piece rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location!=NSNotFound
                           &&[piece canBeConvertedToEncoding:NSASCIIStringEncoding]);
        if(abbreviation&&out.length)[out appendString:@" "];
        if(!abbreviation && i>0) {
            NSString *previous=translated[i-1];
            BOOL previousAbbrev=([previous isEqualToString:previous.uppercaseString]
                                 &&[previous canBeConvertedToEncoding:NSASCIIStringEncoding]
                                 &&[previous rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location!=NSNotFound);
            if(previousAbbrev)[out appendString:@" "];
        }
        [out appendString:piece];
    }
    return out;
}

@implementation ZNMethodTranslator
+ (NSString *)translateMethodName:(NSString *)methodName {
    if(![methodName isKindOfClass:NSString.class]||!methodName.length)return nil;
    static NSCache<NSString *,NSString *> *cache;
    static dispatch_once_t cacheOnce;
    dispatch_once(&cacheOnce,^{cache=[NSCache new];cache.countLimit=512;});
    NSString *cached=[cache objectForKey:methodName];
    if(cached)return [cached isEqualToString:@"<untranslated>"]?nil:cached;
    NSDictionary *dictionary=ZNMP4Dictionary();
    NSArray<NSString *> *chunks=ZNMP4LexicalChunks(methodName);
    NSMutableArray<NSString *> *tokens=[NSMutableArray array];
    for(NSString *chunk in chunks) {
        NSArray *parts=ZNMP4Segment(chunk,dictionary);
        if(!parts.count){[cache setObject:@"<untranslated>" forKey:methodName];return nil;}
        [tokens addObjectsFromArray:parts];
    }
    NSString *translated=ZNMP4Phrase(tokens,dictionary);
    if(!translated.length || [translated isEqualToString:methodName])translated=nil;
    [cache setObject:translated?:@"<untranslated>" forKey:methodName];
    return translated;
}
@end
