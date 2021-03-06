#import "MWMDiscoveryTableManager.h"
#import "MWMDiscoveryTapDelegate.h"
#import "SwiftBridge.h"

#include "DiscoveryControllerViewModel.hpp"

#include "partners_api/locals_api.hpp"
#include "partners_api/viator_api.hpp"

#include "search/result.hpp"

#include "platform/measurement_utils.hpp"

#include "geometry/distance_on_sphere.hpp"
#include "geometry/mercator.hpp"
#include "geometry/point2d.hpp"

#include <algorithm>
#include <iterator>
#include <string>
#include <utility>

using namespace std;
using namespace discovery;

namespace
{
auto const kDefaultRowAnimation = UITableViewRowAnimationFade;

string GetDistance(m2::PointD const & from, m2::PointD const & to)
{
  string distance;
  auto const f = MercatorBounds::ToLatLon(from);
  auto const t = MercatorBounds::ToLatLon(to);
  measurement_utils::FormatDistance(ms::DistanceOnEarth(f.lat, f.lon, t.lat, t.lon), distance);
  return distance;
}
}  // namespace

@interface MWMDiscoveryCollectionView : UICollectionView
@property(nonatomic) ItemType itemType;
@end

@implementation MWMDiscoveryCollectionView
@end

@interface MWMDiscoveryTableManager ()<UITableViewDataSource, UICollectionViewDelegate,
                                       UICollectionViewDataSource>
{
  vector<ItemType> m_types;
  vector<ItemType> m_loadingTypes;
  vector<ItemType> m_failedTypes;
}

@property(weak, nonatomic) UITableView * tableView;
@property(nonatomic) GetModelCallback model;
@property(weak, nonatomic) id<MWMDiscoveryTapDelegate> delegate;

@end

@implementation MWMDiscoveryTableManager

#pragma mark - Public

- (instancetype)initWithTableView:(UITableView *)tableView
                         delegate:(id<MWMDiscoveryTapDelegate>)delegate
                            model:(GetModelCallback &&)modelCallback
{
  self = [super init];
  if (self)
  {
    _tableView = tableView;
    _delegate = delegate;
    _model = move(modelCallback);
    tableView.dataSource = self;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 218;
    [self registerCells];
  }
  return self;
}

- (void)loadItems:(vector<ItemType> const &)types
{
  m_types = types;
  m_loadingTypes = types;
  [self.tableView reloadData];
}

- (void)reloadItem:(ItemType const)type
{
  if (self.model().GetItemsCount(type) == 0)
  {
    [self removeItem:type];
    return;
  }

  m_loadingTypes.erase(remove(m_loadingTypes.begin(), m_loadingTypes.end(), type),
                       m_loadingTypes.end());
  m_failedTypes.erase(remove(m_failedTypes.begin(), m_failedTypes.end(), type),
                      m_failedTypes.end());
  auto const position = [self position:type];
  [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:position]]
                        withRowAnimation:kDefaultRowAnimation];
}

- (void)errorAtItem:(ItemType const)type
{
  CHECK(type == ItemType::Viator || type == ItemType::LocalExperts,
        ("Error on item with type:", static_cast<int>(type)));
  m_loadingTypes.erase(remove(m_loadingTypes.begin(), m_loadingTypes.end(), type),
                       m_loadingTypes.end());
  m_failedTypes.push_back(type);
  auto const position = [self position:type];
  [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:position]
                withRowAnimation:kDefaultRowAnimation];
}

#pragma mark - Private

- (void)removeItem:(ItemType const)type
{
  auto const position = [self position:type];
  m_types.erase(remove(m_types.begin(), m_types.end(), type), m_types.end());
  m_failedTypes.erase(remove(m_failedTypes.begin(), m_failedTypes.end(), type),
                      m_failedTypes.end());
  m_loadingTypes.erase(remove(m_loadingTypes.begin(), m_loadingTypes.end(), type),
                       m_loadingTypes.end());
  [self.tableView deleteSections:[NSIndexSet indexSetWithIndex:position]
                withRowAnimation:kDefaultRowAnimation];
}

- (void)registerCells
{
  auto tv = self.tableView;
  [tv registerWithCellClass:[MWMDiscoverySpinnerCell class]];
  [tv registerWithCellClass:[MWMDiscoveryOnlineTemplateCell class]];
  [tv registerWithCellClass:[MWMDiscoveryCollectionHolderCell class]];
}

- (NSInteger)position:(ItemType const)type
{
  auto const it = find(m_types.begin(), m_types.end(), type);
  if (it == m_types.end())
    CHECK(false, ("Incorrect item type:", static_cast<int>(type)));

  return distance(m_types.begin(), it);
}

- (MWMDiscoveryCollectionHolderCell *)collectionHolderCell:(NSIndexPath *)indexPath
{
  Class cls = [MWMDiscoveryCollectionHolderCell class];
  auto const type = m_types[indexPath.section];
  auto cell = static_cast<MWMDiscoveryCollectionHolderCell *>(
      [self.tableView dequeueReusableCellWithCellClass:cls indexPath:indexPath]);
  auto collection = static_cast<MWMDiscoveryCollectionView *>(cell.collectionView);
  switch (type)
  {
  case ItemType::Viator: [cell configViatorLayout]; break;
  case ItemType::LocalExperts: [cell configLocalExpertsLayout]; break;
  case ItemType::Attractions:
  case ItemType::Cafes: [cell configSearchLayout]; break;
  case ItemType::Hotels: NSAssert(false, @""); return nil;
  }
  collection.delegate = self;
  collection.dataSource = self;
  collection.itemType = type;
  return cell;
}

#pragma mark - UITableViewDataSource

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
  switch (m_types[section])
  {
  case ItemType::Viator: return L(@"discovery_button_subtitle_things_to_do");
  case ItemType::Attractions: return L(@"discovery_button_subtitle_attractions");
  case ItemType::Cafes: return L(@"discovery_button_subtitle_eat_and_drink");
  case ItemType::LocalExperts: return L(@"discovery_button_subtitle_local_guides");
  case ItemType::Hotels: NSAssert(false, @""); return nil;
  }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  auto constexpr kNumberOfRows = 1;
  return kNumberOfRows;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  if (m_types.empty())
  {
    // TODO: Use placeholder
    return nil;
  }

  auto const type = m_types[indexPath.section];
  bool const isFailed =
      find(m_failedTypes.begin(), m_failedTypes.end(), type) != m_failedTypes.end();
  bool const isLoading =
      find(m_loadingTypes.begin(), m_loadingTypes.end(), type) != m_loadingTypes.end();

  switch (type)
  {
  case ItemType::Viator:
  case ItemType::LocalExperts:
  {
    if (isLoading || isFailed)
    {
      Class cls = [MWMDiscoveryOnlineTemplateCell class];
      auto cell = static_cast<MWMDiscoveryOnlineTemplateCell *>(
          [tableView dequeueReusableCellWithCellClass:cls indexPath:indexPath]);
      [cell configWithType:MWMDiscoveryOnlineTemplateTypeViator
               needSpinner:isLoading
                       tap:^{
                         [self.delegate openURLForItem:type];
                       }];
      return cell;
    }
    return [self collectionHolderCell:indexPath];
  }
  case ItemType::Attractions:
  case ItemType::Cafes:
  {
    if (isLoading)
    {
      Class cls = [MWMDiscoverySpinnerCell class];
      auto cell = static_cast<MWMDiscoverySpinnerCell *>(
          [tableView dequeueReusableCellWithCellClass:cls indexPath:indexPath]);
      return cell;
    }
    return [self collectionHolderCell:indexPath];
  }
  case ItemType::Hotels:
  {
    CHECK(false, ("Discovering hotels hasn't implemented yet."));
    return nil;
  }
  }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
  return static_cast<NSInteger>(MAX(m_types.size(), 1));
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(MWMDiscoveryCollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
  [self.delegate tapOnItem:collectionView.itemType atIndex:indexPath.row];
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(MWMDiscoveryCollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section
{
  return self.model().GetItemsCount(collectionView.itemType);
}

- (UICollectionViewCell *)collectionView:(MWMDiscoveryCollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
  auto const type = collectionView.itemType;
  auto const & model = self.model();
  switch (type)
  {
  case ItemType::Attractions:
  case ItemType::Cafes:
  {
    Class cls = [MWMDiscoverySearchCell class];
    auto cell = static_cast<MWMDiscoverySearchCell *>(
        [collectionView dequeueReusableCellWithCellClass:cls indexPath:indexPath]);
    auto const & sr = type == ItemType::Attractions ? model.GetAttractionAt(indexPath.row)
                                                    : model.GetCafeAt(indexPath.row);
    auto const & pt = type == ItemType::Attractions ? model.GetAttractionReferencePoint()
                                                    : model.GetCafeReferencePoint();
    [cell configWithTitle:@(sr.GetString().c_str())
                 subtitle:@(sr.GetFeatureType().c_str())
                 distance:@(GetDistance(pt, sr.GetFeatureCenter()).c_str())
                      tap:^{
                        [self.delegate routeToItem:type atIndex:indexPath.row];
                      }];
    return cell;
  }

  case ItemType::Viator:
  {
    Class cls = [MWMViatorElement class];
    auto cell = static_cast<MWMViatorElement *>(
        [collectionView dequeueReusableCellWithCellClass:cls indexPath:indexPath]);
    auto const & v = model.GetViatorAt(indexPath.row);
    auto imageURL = [NSURL URLWithString:@(v.m_photoUrl.c_str())];
    auto pageURL = [NSURL URLWithString:@(v.m_pageUrl.c_str())];
    auto viatorModel = [[MWMViatorItemModel alloc] initWithImageURL:imageURL
                                                            pageURL:pageURL
                                                              title:@(v.m_title.c_str())
                                                             rating:v.m_rating
                                                           duration:@(v.m_duration.c_str())
                                                              price:@(v.m_priceFormatted.c_str())];
    cell.model = viatorModel;
    return cell;
  }
  case ItemType::LocalExperts: return nil;
  case ItemType::Hotels: NSAssert(false, @""); return nil;
  }
}

@end
