module Main exposing (main)

import Backend exposing (Data, Me)
import Browser
import Browser.Events
import Browser.Navigation as Nav
import Dict exposing (Dict)
import Drag
import ForceGraph as FG exposing (ForceGraph)
import GitHubGraph
import Graph exposing (Graph)
import Hash
import Html exposing (Html)
import Html.Attributes as HA
import Html.Events as HE
import Html.Lazy
import Http
import IntDict exposing (IntDict)
import Log
import Markdown
import OrderedSet exposing (OrderedSet)
import ParseInt
import Path
import Random
import Regex exposing (Regex)
import Set exposing (Set)
import Shape
import Svg exposing (Svg)
import Svg.Attributes as SA
import Svg.Events as SE
import Svg.Lazy
import Task
import Time
import Url exposing (Url)
import Url.Parser as UP exposing ((</>))


type alias Config =
    { initialTime : Int
    }


type alias Model =
    { key : Nav.Key
    , config : Config
    , me : Maybe Me
    , page : Page
    , currentTime : Time.Posix
    , projectDrag : Drag.Model CardSource CardDestination Msg
    , projectDragRefresh : Maybe ProjectDragRefresh
    , milestoneDrag : Drag.Model Card (Maybe String) Msg
    , data : Data
    , isPolling : Bool
    , dataIndex : Int
    , dataView : DataView
    , allCards : Dict GitHubGraph.ID Card
    , allLabels : Dict GitHubGraph.ID GitHubGraph.Label
    , colorLightnessCache : Dict String Bool
    , cardSearch : String
    , selectedCards : OrderedSet GitHubGraph.ID
    , anticipatedCards : Set GitHubGraph.ID
    , highlightedCard : Maybe GitHubGraph.ID
    , highlightedNode : Maybe GitHubGraph.ID
    , baseGraphFilter : Maybe GraphFilter
    , graphFilters : List GraphFilter
    , graphSort : GraphSort
    , cardGraphs : List ( CardNodeState, ForceGraph (Node CardNodeState) )
    , deletingLabels : Set ( String, String )
    , editingLabels : Dict ( String, String ) SharedLabel
    , newLabel : SharedLabel
    , newLabelColored : Bool
    , newMilestoneName : String
    , showLabelFilters : Bool
    , labelSearch : String
    , showLabelOperations : Bool
    , cardLabelOperations : Dict String CardLabelOperation
    , shipItRepoTab : ShipItRepoTab
    }


type alias ProjectDragRefresh =
    { contentId : Maybe GitHubGraph.ID
    , content : Maybe GitHubGraph.CardContent
    , sourceId : Maybe GitHubGraph.ID
    , sourceCards : Maybe (List Backend.ColumnCard)
    , targetId : Maybe GitHubGraph.ID
    , targetCards : Maybe (List Backend.ColumnCard)
    }


type CardLabelOperation
    = AddLabelOperation
    | RemoveLabelOperation


type alias DataView =
    { reposByLabel : Dict ( String, String ) (List GitHubGraph.Repo)
    , prsByRepo : Dict GitHubGraph.ID (List Card)
    , shipItRepos : Dict GitHubGraph.ID ShipItRepo
    }


type alias ShipItRepo =
    { repo : GitHubGraph.Repo
    , nextMilestone : Maybe GitHubGraph.Milestone
    , comparison : GitHubGraph.V3Comparison
    , openPRs : List Card
    , mergedPRs : List Card
    , closedIssues : List Card
    , openIssues : List Card
    , undocumentedCards : List Card
    , documentedCards : List Card
    , leftUndocumentedCards : List Card
    , unreleasedCards : List Card
    }


type ShipItRepoTab
    = ToDoTab
    | UndocumentedTab
    | DocumentedTab
    | LeftUndocumentedTab
    | UnreleasedTab


type GraphFilter
    = ExcludeAllFilter
    | InProjectFilter String
    | HasLabelFilter String String
    | InvolvesUserFilter String
    | IssuesFilter
    | PullRequestsFilter
    | UntriagedFilter


type GraphSort
    = ImpactSort
    | UserActivitySort String
    | AllActivitySort


type alias SharedLabel =
    { name : String
    , color : String
    }


type alias CardNodeState =
    { currentTime : Time.Posix
    , selectedCards : OrderedSet GitHubGraph.ID
    , anticipatedCards : Set GitHubGraph.ID
    , highlightedNode : Maybe GitHubGraph.ID
    , me : Maybe Me
    , dataIndex : Int
    , cardEvents : Dict GitHubGraph.ID (List Backend.EventActor)
    }


type alias Card =
    { id : GitHubGraph.ID
    , content : GitHubGraph.CardContent
    , url : String
    , repo : GitHubGraph.RepoLocation
    , number : Int
    , title : String
    , updatedAt : Time.Posix
    , author : Maybe GitHubGraph.User
    , labels : List GitHubGraph.ID
    , cards : List GitHubGraph.CardLocation
    , commentCount : Int
    , reactions : GitHubGraph.Reactions
    , score : Int
    , state : CardState
    , milestone : Maybe GitHubGraph.Milestone
    , processState : CardProcessState
    }


type alias CardProcessState =
    { inIceboxColumn : Bool
    , inInFlightColumn : Bool
    , inBacklogColumn : Bool
    , inDoneColumn : Bool
    , hasEnhancementLabel : Bool
    , hasBugLabel : Bool
    , hasWontfixLabel : Bool
    , hasPausedLabel : Bool
    }


type CardState
    = IssueState GitHubGraph.IssueState
    | PullRequestState GitHubGraph.PullRequestState


type alias CardDestination =
    { projectId : GitHubGraph.ID
    , columnId : GitHubGraph.ID
    , afterId : Maybe GitHubGraph.ID
    }


type CardSource
    = FromColumnCardSource { columnId : GitHubGraph.ID, cardId : GitHubGraph.ID }
    | NewContentCardSource { contentId : GitHubGraph.ID }


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | Tick Time.Posix
    | RetryPolling
    | SetCurrentTime Time.Posix
    | ProjectDrag (Drag.Msg CardSource CardDestination Msg)
    | MilestoneDrag (Drag.Msg Card (Maybe String) Msg)
    | MoveCardAfter CardSource CardDestination
    | CardMoved GitHubGraph.ID (Result GitHubGraph.Error GitHubGraph.ProjectColumnCard)
    | CardDropContentRefreshed (Result Http.Error (Backend.Indexed GitHubGraph.CardContent))
    | CardDropSourceRefreshed (Result Http.Error (Backend.Indexed (List Backend.ColumnCard)))
    | CardDropTargetRefreshed (Result Http.Error (Backend.Indexed (List Backend.ColumnCard)))
    | CardsRefreshed GitHubGraph.ID (Result Http.Error (Backend.Indexed (List Backend.ColumnCard)))
    | MeFetched (Result Http.Error (Maybe Me))
    | DataFetched (Result Http.Error (Backend.Indexed Data))
    | SelectCard GitHubGraph.ID
    | DeselectCard GitHubGraph.ID
    | HighlightNode GitHubGraph.ID
    | UnhighlightNode GitHubGraph.ID
    | AnticipateCardFromNode GitHubGraph.ID
    | UnanticipateCardFromNode GitHubGraph.ID
    | SearchCards String
    | SelectAnticipatedCards
    | ClearSelectedCards
    | MirrorLabel SharedLabel
    | StartDeletingLabel SharedLabel
    | StopDeletingLabel SharedLabel
    | DeleteLabel SharedLabel
    | StartEditingLabel SharedLabel
    | StopEditingLabel SharedLabel
    | SetLabelName SharedLabel String
    | SetLabelColor String
    | RandomizeLabelColor SharedLabel
    | EditLabel SharedLabel
    | CreateLabel
    | RandomizeNewLabelColor
    | SetNewLabelName String
    | LabelChanged GitHubGraph.Repo (Result GitHubGraph.Error ())
    | RepoRefreshed (Result Http.Error (Backend.Indexed GitHubGraph.Repo))
    | PauseCard Card
    | UnpauseCard Card
    | RefreshIssue GitHubGraph.ID
    | IssueRefreshed (Result Http.Error (Backend.Indexed GitHubGraph.Issue))
    | RefreshPullRequest GitHubGraph.ID
    | PullRequestRefreshed (Result Http.Error (Backend.Indexed GitHubGraph.PullRequest))
    | AddFilter GraphFilter
    | RemoveFilter GraphFilter
    | SetGraphSort GraphSort
    | ToggleLabelFilters
    | SetLabelSearch String
    | ToggleLabelOperations
    | SetLabelOperation String CardLabelOperation
    | UnsetLabelOperation String
    | ApplyLabelOperations
    | DataChanged (Cmd Msg) (Result GitHubGraph.Error ())
    | SetShipItRepoTab ShipItRepoTab


type Page
    = AllProjectsPage
    | GlobalGraphPage
    | ProjectPage String
    | LabelsPage
    | ShipItPage
    | ShipItRepoPage String
    | PullRequestsPage
    | BouncePage


detectColumn : { icebox : String -> Bool, backlog : String -> Bool, inFlight : String -> Bool, done : String -> Bool }
detectColumn =
    { icebox = (==) "Icebox"
    , backlog = String.startsWith "Backlog"
    , inFlight = (==) "In Flight"
    , done = (==) "Done"
    }


main : Program Config Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }


routeParser : UP.Parser (Page -> a) a
routeParser =
    UP.oneOf
        [ UP.map AllProjectsPage UP.top
        , UP.map AllProjectsPage (UP.s "projects")
        , UP.map ProjectPage (UP.s "projects" </> UP.string)
        , UP.map GlobalGraphPage (UP.s "graph")
        , UP.map LabelsPage (UP.s "labels")
        , UP.map ShipItRepoPage (UP.s "shipit" </> UP.string)
        , UP.map ShipItPage (UP.s "shipit")
        , UP.map PullRequestsPage (UP.s "pull-requests")
        , UP.map BouncePage (UP.s "auth" </> UP.s "github")
        , UP.map BouncePage (UP.s "auth")
        , UP.map BouncePage (UP.s "logout")
        ]


type alias CardNodeRadii =
    { base : Float
    , withoutFlair : Float
    , withFlair : Float
    }


type alias NodeBounds =
    { x1 : Float
    , y1 : Float
    , x2 : Float
    , y2 : Float
    }


type alias Position =
    { x : Float
    , y : Float
    }


type alias Node a =
    { card : Card
    , viewLower : Position -> a -> Svg Msg
    , viewUpper : Position -> a -> Svg Msg
    , bounds : Position -> NodeBounds
    , score : Int
    }


init : Config -> Url -> Nav.Key -> ( Model, Cmd Msg )
init config url key =
    let
        model =
            { key = key
            , config = config
            , page = GlobalGraphPage
            , me = Nothing
            , data = Backend.emptyData
            , isPolling = True
            , dataIndex = 0
            , dataView =
                { reposByLabel = Dict.empty
                , prsByRepo = Dict.empty
                , shipItRepos = Dict.empty
                }
            , allCards = Dict.empty
            , allLabels = Dict.empty
            , colorLightnessCache = Dict.empty
            , cardSearch = ""
            , selectedCards = OrderedSet.empty
            , anticipatedCards = Set.empty
            , highlightedCard = Nothing
            , highlightedNode = Nothing
            , currentTime = Time.millisToPosix config.initialTime
            , cardGraphs = []
            , baseGraphFilter = Nothing
            , graphFilters = []
            , graphSort = ImpactSort
            , projectDrag = Drag.init
            , projectDragRefresh = Nothing
            , milestoneDrag = Drag.init
            , deletingLabels = Set.empty
            , editingLabels = Dict.empty
            , newLabel = { name = "", color = "ffffff" }
            , newLabelColored = False
            , newMilestoneName = ""
            , showLabelFilters = False
            , labelSearch = ""
            , showLabelOperations = False
            , cardLabelOperations = Dict.empty
            , shipItRepoTab = UndocumentedTab
            }

        ( navedModel, navedMsgs ) =
            update (UrlChanged url) model
    in
    ( navedModel
    , Cmd.batch
        [ Backend.fetchData DataFetched
        , Backend.fetchMe MeFetched
        , navedMsgs
        ]
    )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every (60 * 60 * 1000) SetCurrentTime
        , Time.every (5 * 1000) (always RetryPolling)
        , if List.all (Tuple.second >> FG.isCompleted) model.cardGraphs then
            Sub.none

          else
            Browser.Events.onAnimationFrame Tick
        ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        RetryPolling ->
            if model.isPolling then
                ( model, Cmd.none )

            else
                ( { model | isPolling = True }, Backend.fetchData DataFetched )

        LinkClicked urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            case UP.parse routeParser url of
                Just BouncePage ->
                    ( model, Nav.load (Url.toString url) )

                Just page ->
                    let
                        baseGraphFilter =
                            case page of
                                AllProjectsPage ->
                                    Just ExcludeAllFilter

                                GlobalGraphPage ->
                                    Nothing

                                ProjectPage name ->
                                    Just (InProjectFilter name)

                                LabelsPage ->
                                    Just ExcludeAllFilter

                                ShipItRepoPage _ ->
                                    Just ExcludeAllFilter

                                ShipItPage ->
                                    Just ExcludeAllFilter

                                PullRequestsPage ->
                                    Just ExcludeAllFilter

                                BouncePage ->
                                    Nothing
                    in
                    ( computeGraph <|
                        computeDataView
                            { model
                                | page = page
                                , baseGraphFilter = baseGraphFilter
                            }
                    , Cmd.none
                    )

                Nothing ->
                    -- 404 would be nice
                    ( model, Cmd.none )

        Tick _ ->
            ( { model
                | cardGraphs =
                    List.map
                        (\( s, g ) ->
                            if FG.isCompleted g then
                                ( s, g )

                            else
                                ( s, FG.tick g )
                        )
                        model.cardGraphs
              }
            , Cmd.none
            )

        SetCurrentTime date ->
            ( computeGraphState { model | currentTime = date }, Cmd.none )

        ProjectDrag subMsg ->
            let
                dragModel =
                    Drag.update subMsg model.projectDrag

                newModel =
                    { model | projectDrag = dragModel }
            in
            case dragModel of
                Drag.Dropping state ->
                    update state.msg { newModel | projectDrag = Drag.drop newModel.projectDrag }

                _ ->
                    ( newModel, Cmd.none )

        MilestoneDrag subMsg ->
            let
                dragModel =
                    Drag.update subMsg model.milestoneDrag

                newModel =
                    { model | milestoneDrag = dragModel }
            in
            case dragModel of
                Drag.Dropping state ->
                    update state.msg { newModel | projectDrag = Drag.drop newModel.projectDrag }

                _ ->
                    ( newModel, Cmd.none )

        MoveCardAfter source dest ->
            case source of
                FromColumnCardSource { cardId } ->
                    ( model, moveCard model dest cardId )

                NewContentCardSource { contentId } ->
                    ( model, addCard model dest contentId )

        CardMoved col (Ok { content }) ->
            case model.projectDrag of
                Drag.Dropped drag ->
                    let
                        wrapValue f indexed =
                            { indexed | value = f indexed.value }

                        ( mcontentId, refreshContent ) =
                            case content of
                                Just (GitHubGraph.IssueCardContent issue) ->
                                    ( Just issue.id
                                    , Backend.refreshIssue issue.id
                                        (CardDropContentRefreshed
                                            << Result.map (\x -> { index = x.index, value = GitHubGraph.IssueCardContent x.value })
                                        )
                                    )

                                Just (GitHubGraph.PullRequestCardContent pr) ->
                                    ( Just pr.id
                                    , Backend.refreshPR pr.id
                                        (CardDropContentRefreshed
                                            << Result.map (\x -> { index = x.index, value = GitHubGraph.PullRequestCardContent x.value })
                                        )
                                    )

                                Nothing ->
                                    ( Nothing, Cmd.none )

                        msourceId =
                            case drag.source of
                                FromColumnCardSource cs ->
                                    if cs.columnId == col then
                                        Nothing

                                    else
                                        Just cs.columnId

                                NewContentCardSource _ ->
                                    Nothing
                    in
                    case msourceId of
                        Just sourceId ->
                            ( { model
                                | projectDragRefresh =
                                    Just
                                        { contentId = mcontentId
                                        , content = Nothing
                                        , sourceId = Just sourceId
                                        , sourceCards = Nothing
                                        , targetId = Just col
                                        , targetCards = Nothing
                                        }
                              }
                            , Cmd.batch
                                [ refreshContent
                                , Backend.refreshCards sourceId CardDropSourceRefreshed
                                , Backend.refreshCards col CardDropTargetRefreshed
                                ]
                            )

                        Nothing ->
                            ( { model
                                | projectDragRefresh =
                                    Just
                                        { contentId = mcontentId
                                        , content = Nothing
                                        , sourceId = Nothing
                                        , sourceCards = Nothing
                                        , targetId = Just col
                                        , targetCards = Nothing
                                        }
                              }
                            , Cmd.batch
                                [ refreshContent
                                , Backend.refreshCards col CardDropTargetRefreshed
                                ]
                            )

                _ ->
                    ( model, Cmd.none )

        CardMoved col (Err err) ->
            Log.debug "failed to move card" err <|
                ( model, Cmd.none )

        CardDropContentRefreshed (Ok { index, value }) ->
            case model.projectDragRefresh of
                Nothing ->
                    ( model, Cmd.none )

                Just pdr ->
                    ( finishProjectDragRefresh
                        { model
                            | projectDragRefresh = Just { pdr | content = Just value }
                            , dataIndex = max index model.dataIndex
                        }
                    , Cmd.none
                    )

        CardDropContentRefreshed (Err err) ->
            Log.debug "failed to refresh card" err <|
                ( model, Cmd.none )

        CardDropSourceRefreshed (Ok { index, value }) ->
            case model.projectDragRefresh of
                Nothing ->
                    ( model, Cmd.none )

                Just pdr ->
                    ( finishProjectDragRefresh
                        { model
                            | projectDragRefresh = Just { pdr | sourceCards = Just value }
                            , dataIndex = max index model.dataIndex
                        }
                    , Cmd.none
                    )

        CardDropSourceRefreshed (Err err) ->
            Log.debug "failed to refresh card" err <|
                ( model, Cmd.none )

        CardDropTargetRefreshed (Ok { index, value }) ->
            case model.projectDragRefresh of
                Nothing ->
                    ( model, Cmd.none )

                Just pdr ->
                    ( finishProjectDragRefresh
                        { model
                            | projectDragRefresh = Just { pdr | targetCards = Just value }
                            , dataIndex = max index model.dataIndex
                        }
                    , Cmd.none
                    )

        CardDropTargetRefreshed (Err err) ->
            Log.debug "failed to refresh card" err <|
                ( model, Cmd.none )

        CardsRefreshed col (Ok { index, value }) ->
            let
                data =
                    model.data

                newData =
                    { data | columnCards = Dict.insert col value data.columnCards }
            in
            ( computeDataView { model | data = newData, dataIndex = max index model.dataIndex }, Cmd.none )

        CardsRefreshed col (Err err) ->
            Log.debug "failed to refresh cards" err <|
                ( model, Cmd.none )

        SearchCards str ->
            let
                tokens =
                    String.split " " str

                ( filterTokens, rest ) =
                    List.partition (String.contains ":") tokens

                filters =
                    List.map (String.split ":") filterTokens

                query =
                    String.toLower (String.join " " rest)

                cardsByTitle =
                    Dict.foldl
                        (\_ card ->
                            Dict.insert (String.toLower card.title) card
                        )
                        Dict.empty
                        model.allCards

                cardMatch title card =
                    if String.length query < 2 && List.isEmpty filters then
                        False

                    else if String.contains query title then
                        (\a -> List.all a filters) <|
                            \filter ->
                                case filter of
                                    [ "label", name ] ->
                                        hasLabel model name card

                                    _ ->
                                        False

                    else
                        False

                foundCards =
                    Dict.filter cardMatch cardsByTitle
                        |> Dict.foldl (\_ card -> Set.insert card.id) Set.empty
            in
            ( computeGraphState
                { model
                    | cardSearch = str
                    , anticipatedCards = foundCards
                }
            , Cmd.none
            )

        SelectAnticipatedCards ->
            ( computeGraphState
                { model
                    | anticipatedCards = Set.empty
                    , selectedCards = Set.foldr OrderedSet.insert model.selectedCards model.anticipatedCards
                }
            , Cmd.none
            )

        SelectCard id ->
            ( computeGraphState { model | selectedCards = OrderedSet.insert id model.selectedCards }
            , Cmd.none
            )

        ClearSelectedCards ->
            ( computeGraphState { model | selectedCards = OrderedSet.empty }
            , Cmd.none
            )

        DeselectCard id ->
            ( computeGraphState { model | selectedCards = OrderedSet.remove id model.selectedCards }
            , Cmd.none
            )

        HighlightNode id ->
            ( computeGraphState { model | highlightedNode = Just id }, Cmd.none )

        UnhighlightNode id ->
            ( computeGraphState { model | highlightedNode = Nothing }, Cmd.none )

        AnticipateCardFromNode id ->
            ( computeGraphState
                { model
                    | anticipatedCards = Set.insert id model.anticipatedCards
                    , highlightedCard = Just id
                }
            , Cmd.none
            )

        UnanticipateCardFromNode id ->
            ( computeGraphState
                { model
                    | anticipatedCards = Set.remove id model.anticipatedCards
                    , highlightedCard = Nothing
                }
            , Cmd.none
            )

        MeFetched (Ok me) ->
            ( computeGraphState { model | me = me }, Cmd.none )

        MeFetched (Err err) ->
            Log.debug "error fetching self" err <|
                ( model, Cmd.none )

        DataFetched (Ok { index, value }) ->
            ( if index > model.dataIndex then
                let
                    issueCards =
                        Dict.map (\_ -> issueCard) value.issues

                    prCards =
                        Dict.map (\_ -> prCard) value.prs

                    allCards =
                        Dict.union issueCards prCards

                    allLabels =
                        Dict.foldl (\_ r ls -> List.foldl (\l -> Dict.insert l.id l) ls r.labels) Dict.empty value.repos

                    colorLightnessCache =
                        Dict.foldl
                            (\_ { color } cache ->
                                Dict.insert color (computeColorIsLight color) cache
                            )
                            Dict.empty
                            allLabels
                in
                computeGraphState <|
                    computeGraph <|
                        computeDataView <|
                            { model
                                | data = value
                                , dataIndex = index
                                , allCards = allCards
                                , allLabels = allLabels
                                , colorLightnessCache = colorLightnessCache
                            }

              else
                Log.debug "ignoring stale index" ( index, model.dataIndex ) <|
                    model
            , Backend.pollData DataFetched
            )

        DataFetched (Err err) ->
            Log.debug "error fetching data" err <|
                ( { model | isPolling = False }, Cmd.none )

        MirrorLabel newLabel ->
            let
                cmds =
                    Dict.foldl
                        (\_ r acc ->
                            case List.filter ((==) newLabel.name << .name) r.labels of
                                [] ->
                                    createLabel model r newLabel :: acc

                                label :: _ ->
                                    if label.color == newLabel.color then
                                        acc

                                    else
                                        updateLabel model r label newLabel :: acc
                        )
                        []
                        model.data.repos
            in
            ( model, Cmd.batch cmds )

        StartDeletingLabel label ->
            ( { model | deletingLabels = Set.insert (labelKey label) model.deletingLabels }, Cmd.none )

        StopDeletingLabel label ->
            ( { model | deletingLabels = Set.remove (labelKey label) model.deletingLabels }, Cmd.none )

        DeleteLabel label ->
            let
                cmds =
                    Dict.foldl
                        (\_ r acc ->
                            case List.filter (matchesLabel label) r.labels of
                                [] ->
                                    acc

                                repoLabel :: _ ->
                                    deleteLabel model r repoLabel :: acc
                        )
                        []
                        model.data.repos
            in
            ( { model | deletingLabels = Set.remove (labelKey label) model.deletingLabels }, Cmd.batch cmds )

        StartEditingLabel label ->
            ( { model | editingLabels = Dict.insert (labelKey label) label model.editingLabels }, Cmd.none )

        StopEditingLabel label ->
            ( { model | editingLabels = Dict.remove (labelKey label) model.editingLabels }, Cmd.none )

        SetLabelName label newName ->
            ( { model
                | editingLabels =
                    Dict.update (labelKey label) (Maybe.map (\newLabel -> { newLabel | name = newName })) model.editingLabels
              }
            , Cmd.none
            )

        SetLabelColor newColor ->
            let
                newLabel =
                    model.newLabel
            in
            ( { model
                | newLabel =
                    if String.isEmpty newLabel.name then
                        newLabel

                    else
                        { newLabel | color = newColor }
                , newLabelColored = not (String.isEmpty newLabel.name)
                , editingLabels =
                    Dict.map (\_ label -> { label | color = newColor }) model.editingLabels
              }
            , Cmd.none
            )

        RandomizeLabelColor label ->
            case Dict.get (labelKey label) model.editingLabels of
                Nothing ->
                    ( model, Cmd.none )

                Just newLabel ->
                    ( { model
                        | editingLabels =
                            Dict.insert (labelKey label) (randomizeColor newLabel) model.editingLabels
                      }
                    , Cmd.none
                    )

        EditLabel oldLabel ->
            case Dict.get (labelKey oldLabel) model.editingLabels of
                Nothing ->
                    ( model, Cmd.none )

                Just newLabel ->
                    let
                        cmds =
                            Dict.foldl
                                (\_ r acc ->
                                    case List.filter (matchesLabel oldLabel) r.labels of
                                        repoLabel :: _ ->
                                            updateLabel model r repoLabel newLabel :: acc

                                        _ ->
                                            acc
                                )
                                []
                                model.data.repos
                    in
                    ( { model | editingLabels = Dict.remove (labelKey oldLabel) model.editingLabels }, Cmd.batch cmds )

        CreateLabel ->
            if model.newLabel.name == "" then
                ( model, Cmd.none )

            else
                update (MirrorLabel model.newLabel)
                    { model
                        | newLabel = { name = "", color = "ffffff" }
                        , newLabelColored = False
                    }

        RandomizeNewLabelColor ->
            ( { model | newLabel = randomizeColor model.newLabel, newLabelColored = True }, Cmd.none )

        SetNewLabelName name ->
            let
                newLabel =
                    model.newLabel

                newColor =
                    if model.newLabelColored then
                        model.newLabel.color

                    else
                        generateColor (Hash.hash name)
            in
            ( { model | newLabel = { newLabel | name = name, color = newColor } }, Cmd.none )

        LabelChanged repo (Ok ()) ->
            let
                repoSel =
                    { owner = repo.owner, name = repo.name }
            in
            ( model, Backend.refreshRepo repoSel RepoRefreshed )

        LabelChanged repo (Err err) ->
            Log.debug "failed to modify labels" err <|
                ( model, Cmd.none )

        RepoRefreshed (Ok { index, value }) ->
            let
                data =
                    model.data

                allLabels =
                    List.foldl (\l -> Dict.insert l.id l) model.allLabels value.labels

                colorLightnessCache =
                    Dict.foldl
                        (\_ { color } cache ->
                            Dict.insert color (computeColorIsLight color) cache
                        )
                        Dict.empty
                        allLabels
            in
            ( computeDataView
                { model
                    | data = { data | repos = Dict.insert value.id value data.repos }
                    , dataIndex = max index model.dataIndex
                    , allLabels = allLabels
                    , colorLightnessCache = colorLightnessCache
                }
            , Cmd.none
            )

        RepoRefreshed (Err err) ->
            Log.debug "failed to refresh repo" err <|
                ( model, Cmd.none )

        PauseCard card ->
            case card.content of
                GitHubGraph.IssueCardContent issue ->
                    ( model, addIssueLabels model issue [ "paused" ] )

                GitHubGraph.PullRequestCardContent pr ->
                    ( model, addPullRequestLabels model pr [ "paused" ] )

        UnpauseCard card ->
            case card.content of
                GitHubGraph.IssueCardContent issue ->
                    ( model, removeIssueLabel model issue "paused" )

                GitHubGraph.PullRequestCardContent pr ->
                    ( model, removePullRequestLabel model pr "paused" )

        DataChanged cb (Ok ()) ->
            ( model, cb )

        DataChanged cb (Err err) ->
            Log.debug "failed to change data" err <|
                ( model, Cmd.none )

        RefreshIssue id ->
            ( model, Backend.refreshIssue id IssueRefreshed )

        IssueRefreshed (Ok { index, value }) ->
            ( computeDataView
                { model
                    | milestoneDrag = Drag.complete model.milestoneDrag
                    , allCards = Dict.insert value.id (issueCard value) model.allCards
                    , dataIndex = max index model.dataIndex
                }
            , Cmd.none
            )

        IssueRefreshed (Err err) ->
            Log.debug "failed to refresh issue" err <|
                ( model, Cmd.none )

        RefreshPullRequest id ->
            ( model, Backend.refreshPR id PullRequestRefreshed )

        PullRequestRefreshed (Ok { index, value }) ->
            ( computeDataView
                { model
                    | milestoneDrag = Drag.complete model.milestoneDrag
                    , allCards = Dict.insert value.id (prCard value) model.allCards
                    , dataIndex = max index model.dataIndex
                }
            , Cmd.none
            )

        PullRequestRefreshed (Err err) ->
            Log.debug "failed to refresh pr" err <|
                ( model, Cmd.none )

        AddFilter filter ->
            ( computeGraph <|
                { model | graphFilters = filter :: model.graphFilters }
            , Cmd.none
            )

        RemoveFilter filter ->
            ( computeGraph <|
                { model | graphFilters = List.filter ((/=) filter) model.graphFilters }
            , Cmd.none
            )

        SetGraphSort sort ->
            ( computeGraph { model | graphSort = sort }, Cmd.none )

        ToggleLabelFilters ->
            ( { model | showLabelFilters = not model.showLabelFilters }, Cmd.none )

        SetLabelSearch string ->
            ( { model | labelSearch = string }, Cmd.none )

        ToggleLabelOperations ->
            ( if model.showLabelOperations then
                { model
                    | showLabelOperations = False
                    , labelSearch = ""
                    , cardLabelOperations = Dict.empty
                }

              else
                computeDataView { model | showLabelOperations = True }
            , Cmd.none
            )

        SetLabelOperation name op ->
            ( { model | cardLabelOperations = Dict.insert name op model.cardLabelOperations }, Cmd.none )

        UnsetLabelOperation name ->
            ( { model | cardLabelOperations = Dict.remove name model.cardLabelOperations }, Cmd.none )

        ApplyLabelOperations ->
            let
                cards =
                    List.filterMap (\a -> Dict.get a model.allCards) (OrderedSet.toList model.selectedCards)

                ( addPairs, removePairs ) =
                    Dict.toList model.cardLabelOperations
                        |> List.partition ((==) AddLabelOperation << Tuple.second)

                labelsToAdd =
                    List.map Tuple.first addPairs

                labelsToRemove =
                    List.map Tuple.first removePairs

                adds =
                    List.map
                        (\card ->
                            case card.content of
                                GitHubGraph.IssueCardContent issue ->
                                    addIssueLabels model issue labelsToAdd

                                GitHubGraph.PullRequestCardContent pr ->
                                    addPullRequestLabels model pr labelsToAdd
                        )
                        cards

                removals =
                    List.concatMap
                        (\name ->
                            List.filterMap
                                (\card ->
                                    if hasLabel model name card then
                                        case card.content of
                                            GitHubGraph.IssueCardContent issue ->
                                                Just (removeIssueLabel model issue name)

                                            GitHubGraph.PullRequestCardContent pr ->
                                                Just (removePullRequestLabel model pr name)

                                    else
                                        Nothing
                                )
                                cards
                        )
                        labelsToRemove
            in
            ( model, Cmd.batch (adds ++ removals) )

        SetShipItRepoTab tab ->
            ( { model | shipItRepoTab = tab }, Cmd.none )


computeGraphState : Model -> Model
computeGraphState model =
    let
        newState =
            { currentTime = model.currentTime
            , selectedCards = model.selectedCards
            , anticipatedCards = model.anticipatedCards
            , highlightedNode = model.highlightedNode
            , me = model.me
            , dataIndex = model.dataIndex
            , cardEvents = model.data.actors
            }

        affectedByState { graph } =
            Graph.fold
                (\{ node } affected ->
                    if affected then
                        True

                    else
                        let
                            id =
                                node.label.value.card.id
                        in
                        OrderedSet.member id newState.selectedCards
                            || Set.member id newState.anticipatedCards
                            || (newState.highlightedNode == Just id)
                )
                False
                graph
    in
    { model
        | cardGraphs =
            List.map
                (\( s, g ) ->
                    if affectedByState g then
                        ( newState, g )

                    else if isBaseGraphState model s then
                        ( s, g )

                    else
                        ( baseGraphState model, g )
                )
                model.cardGraphs
    }


computeDataView : Model -> Model
computeDataView origModel =
    let
        add x =
            Just << Maybe.withDefault [ x ] << Maybe.map ((::) x)

        groupRepoLabels =
            Dict.foldl
                (\_ repo cbn ->
                    List.foldl
                        (\label -> Dict.update ( label.name, String.toLower label.color ) (add repo))
                        cbn
                        repo.labels
                )
                Dict.empty

        origDataView =
            origModel.dataView

        dataView =
            { origDataView | reposByLabel = groupRepoLabels origModel.data.repos }

        model =
            { origModel | dataView = dataView }
    in
    case model.page of
        ShipItPage ->
            { model | dataView = { dataView | shipItRepos = computeShipItRepos model } }

        ShipItRepoPage _ ->
            { model | dataView = { dataView | shipItRepos = computeShipItRepos model } }

        PullRequestsPage ->
            let
                prsByRepo =
                    Dict.foldl
                        (\_ card acc ->
                            if isOpen card && isPR card then
                                Dict.update card.repo.id (add card) acc

                            else
                                acc
                        )
                        Dict.empty
                        model.allCards
            in
            { model | dataView = { dataView | prsByRepo = prsByRepo } }

        LabelsPage ->
            model

        GlobalGraphPage ->
            model

        ProjectPage _ ->
            model

        AllProjectsPage ->
            model

        BouncePage ->
            model


computeShipItRepos : Model -> Dict String ShipItRepo
computeShipItRepos model =
    let
        selectPRsInComparison comparison prId pr acc =
            case pr.mergeCommit of
                Nothing ->
                    acc

                Just { sha } ->
                    if List.any ((==) sha << .sha) comparison.commits then
                        case Dict.get prId model.allCards of
                            Just prc ->
                                prc :: acc

                            Nothing ->
                                acc

                    else
                        acc

        selectCardsInMilestone milestone cardId card acc =
            case card.milestone of
                Nothing ->
                    acc

                Just { id } ->
                    -- don't double-count merged PRs - they are collected via the
                    -- comparison
                    if milestone.id == id && not (isMerged card) then
                        card :: acc

                    else
                        acc

        makeShipItRepo repoId comparison acc =
            if comparison.totalCommits == 0 then
                acc

            else
                case Dict.get repoId model.data.repos of
                    Just repo ->
                        let
                            nextMilestone =
                                repo.milestones
                                    |> List.filter ((==) GitHubGraph.MilestoneStateOpen << .state)
                                    |> List.sortBy .number
                                    |> List.head

                            mergedPRs =
                                Dict.foldl (selectPRsInComparison comparison) [] model.data.prs

                            milestoneCards =
                                case nextMilestone of
                                    Nothing ->
                                        []

                                    Just nm ->
                                        Dict.foldl (selectCardsInMilestone nm) [] model.allCards

                            allCards =
                                milestoneCards ++ mergedPRs

                            categorizeByDocumentedState card sir =
                                if hasLabel model "documented" card then
                                    { sir | documentedCards = card :: sir.documentedCards }

                                else if hasLabel model "left-undocumented" card then
                                    { sir | leftUndocumentedCards = card :: sir.leftUndocumentedCards }

                                else if hasLabel model "unreleased" card then
                                    { sir | unreleasedCards = card :: sir.unreleasedCards }

                                else
                                    { sir | undocumentedCards = card :: sir.undocumentedCards }

                            categorizeByCardState card sir =
                                case card.state of
                                    IssueState GitHubGraph.IssueStateOpen ->
                                        { sir | openIssues = card :: sir.openIssues }

                                    IssueState GitHubGraph.IssueStateClosed ->
                                        { sir | closedIssues = card :: sir.closedIssues }

                                    PullRequestState GitHubGraph.PullRequestStateOpen ->
                                        { sir | openPRs = card :: sir.openPRs }

                                    PullRequestState GitHubGraph.PullRequestStateMerged ->
                                        { sir | mergedPRs = card :: sir.mergedPRs }

                                    PullRequestState GitHubGraph.PullRequestStateClosed ->
                                        -- ignored
                                        sir

                            categorizeCard card sir =
                                let
                                    byState =
                                        categorizeByCardState card sir
                                in
                                if isOpen card then
                                    byState

                                else
                                    categorizeByDocumentedState card byState

                            shipItRepo =
                                List.foldl categorizeCard
                                    { repo = repo
                                    , nextMilestone = nextMilestone
                                    , comparison = comparison
                                    , openPRs = []
                                    , mergedPRs = []
                                    , openIssues = []
                                    , closedIssues = []
                                    , undocumentedCards = []
                                    , documentedCards = []
                                    , leftUndocumentedCards = []
                                    , unreleasedCards = []
                                    }
                                    allCards
                        in
                        Dict.insert repo.name shipItRepo acc

                    Nothing ->
                        acc
    in
    Dict.foldl makeShipItRepo Dict.empty model.data.comparisons


cardProcessState : { cards : List GitHubGraph.CardLocation, labels : List GitHubGraph.Label } -> CardProcessState
cardProcessState { cards, labels } =
    { inIceboxColumn = inColumn detectColumn.icebox cards
    , inInFlightColumn = inColumn detectColumn.inFlight cards
    , inBacklogColumn = inColumn detectColumn.backlog cards
    , inDoneColumn = inColumn detectColumn.done cards
    , hasEnhancementLabel = List.any ((==) "enhancement" << .name) labels
    , hasBugLabel = List.any ((==) "bug" << .name) labels
    , hasWontfixLabel = List.any ((==) "wontfix" << .name) labels
    , hasPausedLabel = List.any ((==) "paused" << .name) labels
    }


issueCard : GitHubGraph.Issue -> Card
issueCard ({ id, url, repo, number, title, updatedAt, author, labels, cards, commentCount, reactions, state, milestone } as issue) =
    { id = id
    , content = GitHubGraph.IssueCardContent issue
    , url = url
    , repo = repo
    , number = number
    , title = title
    , updatedAt = updatedAt
    , author = author
    , labels = List.map .id labels
    , cards = cards
    , commentCount = commentCount
    , reactions = reactions
    , score = GitHubGraph.issueScore issue
    , state = IssueState state
    , milestone = milestone
    , processState = cardProcessState { cards = cards, labels = labels }
    }


prCard : GitHubGraph.PullRequest -> Card
prCard ({ id, url, repo, number, title, updatedAt, author, labels, cards, commentCount, reactions, state, milestone } as pr) =
    { id = id
    , content = GitHubGraph.PullRequestCardContent pr
    , url = url
    , repo = repo
    , number = number
    , title = title
    , updatedAt = updatedAt
    , author = author
    , labels = List.map .id labels
    , cards = cards
    , commentCount = commentCount
    , reactions = reactions
    , score = GitHubGraph.pullRequestScore pr
    , state = PullRequestState state
    , milestone = milestone
    , processState = cardProcessState { cards = cards, labels = labels }
    }


view : Model -> Browser.Document Msg
view model =
    { title = "Cadet"
    , body = [ viewPage model ]
    }


viewPage : Model -> Html Msg
viewPage model =
    let
        anticipatedCards =
            List.map (viewCardEntry model) <|
                List.filterMap (\a -> Dict.get a model.allCards) <|
                    List.filter (not << (\a -> OrderedSet.member a model.selectedCards)) (Set.toList model.anticipatedCards)

        selectedCards =
            List.map (viewCardEntry model) <|
                List.filterMap (\a -> Dict.get a model.allCards) (OrderedSet.toList model.selectedCards)

        sidebarCards =
            anticipatedCards ++ List.reverse selectedCards
    in
    Html.div [ HA.class "cadet" ]
        [ viewNavBar model
        , Html.div
            [ HA.class "main-page"
            , HA.class (pageClass model.page)
            ]
            [ Html.div [ HA.class "page-content" ]
                [ case model.page of
                    AllProjectsPage ->
                        viewAllProjectsPage model

                    GlobalGraphPage ->
                        viewSpatialGraph model

                    ProjectPage id ->
                        viewProjectPage model id

                    LabelsPage ->
                        viewLabelsPage model

                    ShipItPage ->
                        viewShipItPage model

                    ShipItRepoPage repoName ->
                        case Dict.get repoName model.dataView.shipItRepos of
                            Just sir ->
                                viewShipItRepoPage model sir

                            Nothing ->
                                Html.text "repo not found"

                    PullRequestsPage ->
                        viewPullRequestsPage model

                    BouncePage ->
                        Html.text "you shouldn't see this"
                ]
            , Html.div
                [ HA.classList
                    [ ( "page-sidebar", True )
                    , ( "empty", List.isEmpty sidebarCards )
                    ]
                ]
                [ viewSidebarControls model
                , if List.isEmpty sidebarCards then
                    Html.div [ HA.class "no-cards" ]
                        [ Html.text "no cards selected" ]

                  else
                    Html.div [ HA.class "cards" ] sidebarCards
                ]
            ]
        ]


pageClass : Page -> String
pageClass page =
    case page of
        ShipItRepoPage _ ->
            "shipit-repo-page"

        GlobalGraphPage ->
            "contains-graph"

        ProjectPage _ ->
            "contains-graph"

        _ ->
            "normal"


viewSidebarControls : Model -> Html Msg
viewSidebarControls model =
    let
        viewLabelOperation name color =
            let
                ( checkClass, clickOperation ) =
                    case Dict.get name model.cardLabelOperations of
                        Just AddLabelOperation ->
                            ( "checked octicon octicon-check", SetLabelOperation name RemoveLabelOperation )

                        Just RemoveLabelOperation ->
                            ( "unhecked octicon", UnsetLabelOperation name )

                        Nothing ->
                            let
                                cards =
                                    List.filterMap (\a -> Dict.get a model.allCards) (OrderedSet.toList model.selectedCards)
                            in
                            if not (List.isEmpty cards) && List.all (hasLabel model name) cards then
                                ( "checked octicon octicon-check", SetLabelOperation name RemoveLabelOperation )

                            else if List.any (hasLabel model name) cards then
                                ( "mixed octicon octicon-dash", SetLabelOperation name AddLabelOperation )

                            else
                                ( "unchecked octicon", SetLabelOperation name AddLabelOperation )
            in
            Html.div [ HA.class "label-operation" ]
                [ Html.span [ HA.class ("checkbox " ++ checkClass), HE.onClick clickOperation ] []
                , Html.span
                    ([ HA.class "label"
                     , HE.onClick (AddFilter (HasLabelFilter name color))
                     ]
                        ++ labelColorStyles model color
                    )
                    [ octicon "tag"
                    , Html.text name
                    ]
                ]

        labelOptions =
            if model.showLabelOperations then
                Dict.keys model.dataView.reposByLabel
                    |> List.filter (String.contains model.labelSearch << Tuple.first)
                    |> List.map (\( a, b ) -> viewLabelOperation a b)

            else
                []
    in
    Html.div [ HA.class "sidebar-controls" ]
        [ Html.div [ HA.class "control-knobs" ]
            [ Html.span [ HA.class "controls-label" ] [ Html.text "change:" ]
            , Html.div
                [ HA.classList [ ( "control-setting", True ), ( "active", model.showLabelOperations ) ]
                , HE.onClick ToggleLabelOperations
                ]
                [ octicon "tag"
                , Html.text "labels"
                ]
            , Html.span
                [ HE.onClick ClearSelectedCards
                , HA.class "octicon octicon-x clear-selected"
                ]
                [ Html.text "" ]
            ]
        , Html.div [ HA.classList [ ( "label-operations", True ), ( "visible", model.showLabelOperations ) ] ]
            [ Html.input [ HA.type_ "text", HA.placeholder "search labels", HE.onInput SetLabelSearch ] []
            , Html.div [ HA.class "label-options" ] labelOptions
            , Html.div [ HA.class "buttons" ]
                [ Html.div [ HA.class "button cancel", HE.onClick ToggleLabelOperations ]
                    [ octicon "x"
                    , Html.text "cancel"
                    ]
                , Html.div [ HA.class "button apply", HE.onClick ApplyLabelOperations ]
                    [ octicon "check"
                    , Html.text "apply"
                    ]
                ]
            ]
        ]


viewSpatialGraph : Model -> Html Msg
viewSpatialGraph model =
    Html.div [ HA.class "spatial-graph" ] <|
        viewGraphControls model
            :: List.map ((\f ( a, b ) -> f a b) <| Html.Lazy.lazy2 viewGraph) model.cardGraphs


viewGraphControls : Model -> Html Msg
viewGraphControls model =
    let
        labelFilters =
            List.filterMap
                (\filter ->
                    case filter of
                        HasLabelFilter name color ->
                            Just <|
                                Html.div
                                    ([ HA.class "control-setting"
                                     , HE.onClick (RemoveFilter filter)
                                     ]
                                        ++ labelColorStyles model color
                                    )
                                    [ octicon "tag"
                                    , Html.text name
                                    ]

                        _ ->
                            Nothing
                )
                model.graphFilters

        allLabelFilters =
            (\a -> List.filterMap a (Dict.toList model.dataView.reposByLabel)) <|
                \( ( name, color ), _ ) ->
                    if String.contains model.labelSearch name then
                        Just <|
                            Html.div [ HA.class "label-filter" ]
                                [ Html.div
                                    ([ HA.class "label"
                                     , HE.onClick (AddFilter (HasLabelFilter name color))
                                     ]
                                        ++ labelColorStyles model color
                                    )
                                    [ octicon "tag"
                                    , Html.text name
                                    ]
                                ]

                    else
                        Nothing
    in
    Html.div [ HA.class "graph-controls" ]
        [ Html.div [ HA.class "control-group" ]
            ([ Html.span [ HA.class "controls-label" ] [ Html.text "filter:" ]
             , let
                filter =
                    UntriagedFilter
               in
               Html.div
                [ HA.classList [ ( "control-setting", True ), ( "active", hasFilter model filter ) ]
                , HE.onClick <|
                    if hasFilter model filter then
                        RemoveFilter filter

                    else
                        AddFilter filter
                ]
                [ octicon "inbox"
                , Html.text "untriaged"
                ]
             , let
                filter =
                    IssuesFilter
               in
               Html.div
                [ HA.classList [ ( "control-setting", True ), ( "active", hasFilter model filter ) ]
                , HE.onClick <|
                    if hasFilter model filter then
                        RemoveFilter filter

                    else
                        AddFilter filter
                ]
                [ octicon "issue-opened"
                , Html.text "issues"
                ]
             , let
                filter =
                    PullRequestsFilter
               in
               Html.div
                [ HA.classList [ ( "control-setting", True ), ( "active", hasFilter model filter ) ]
                , HE.onClick <|
                    if hasFilter model filter then
                        RemoveFilter filter

                    else
                        AddFilter filter
                ]
                [ octicon "git-pull-request"
                , Html.text "pull requests"
                ]
             , case model.me of
                Just { user } ->
                    let
                        filter =
                            InvolvesUserFilter user.login
                    in
                    Html.div
                        [ HA.classList [ ( "control-setting", True ), ( "active", hasFilter model filter ) ]
                        , HE.onClick <|
                            if hasFilter model filter then
                                RemoveFilter filter

                            else
                                AddFilter filter
                        ]
                        [ octicon "comment-discussion"
                        , Html.text "involving me"
                        ]

                Nothing ->
                    Html.text ""
             , Html.div [ HA.class "label-selection" ]
                [ Html.div [ HA.classList [ ( "label-filters", True ), ( "visible", model.showLabelFilters ) ] ]
                    [ Html.div [ HA.class "label-options" ]
                        allLabelFilters
                    , Html.input [ HA.type_ "text", HE.onInput SetLabelSearch ] []
                    ]
                , Html.div
                    [ HA.classList [ ( "control-setting", True ), ( "active", model.showLabelFilters ) ]
                    , HE.onClick ToggleLabelFilters
                    ]
                    [ octicon "tag"
                    , Html.text "label"
                    ]
                ]
             ]
                ++ labelFilters
            )
        , Html.div [ HA.class "control-group" ]
            [ Html.span [ HA.class "controls-label" ] [ Html.text "sort:" ]
            , Html.div
                [ HA.classList [ ( "control-setting", True ), ( "active", model.graphSort == ImpactSort ) ]
                , HE.onClick (SetGraphSort ImpactSort)
                ]
                [ octicon "flame"
                , Html.text "impact"
                ]
            , Html.div
                [ HA.classList [ ( "control-setting", True ), ( "active", model.graphSort == AllActivitySort ) ]
                , HE.onClick (SetGraphSort AllActivitySort)
                ]
                [ octicon "clock"
                , Html.text "all activity"
                ]
            , case model.me of
                Just { user } ->
                    Html.div
                        [ HA.classList [ ( "control-setting", True ), ( "active", model.graphSort == UserActivitySort user.login ) ]
                        , HE.onClick (SetGraphSort (UserActivitySort user.login))
                        ]
                        [ octicon "clock"
                        , Html.text "my activity"
                        ]

                Nothing ->
                    Html.text ""
            ]
        ]


hasFilter : Model -> GraphFilter -> Bool
hasFilter model filter =
    List.member filter model.graphFilters


viewNavBar : Model -> Html Msg
viewNavBar model =
    Html.div [ HA.class "nav-bar" ]
        [ Html.div [ HA.class "nav" ]
            [ case model.me of
                Nothing ->
                    Html.a [ HA.class "button user-info", HA.href "/auth/github" ]
                        [ Html.span [ HA.class "log-in-icon octicon octicon-sign-in" ] []
                        , Html.text "log in"
                        ]

                Just { user } ->
                    Html.a [ HA.class "button user-info", HA.href user.url ]
                        [ Html.img [ HA.class "user-avatar", HA.src user.avatar ] []
                        , Html.text user.login
                        ]
            , Html.a [ HA.class "button", HA.href "/" ]
                [ octicon "list-unordered"
                ]
            , Html.a [ HA.class "button", HA.href "/graph" ]
                [ octicon "circuit-board"
                ]
            , Html.a [ HA.class "button", HA.href "/pull-requests" ]
                [ octicon "git-pull-request"
                ]
            , Html.a [ HA.class "button", HA.href "/shipit" ]
                [ octicon "squirrel"
                ]
            , Html.a [ HA.class "button", HA.href "/labels" ]
                [ octicon "tag"
                ]
            ]
        , viewSearch model
        ]


type alias ProjectState =
    { project : GitHubGraph.Project
    , icebox : GitHubGraph.ProjectColumn
    , backlogs : List GitHubGraph.ProjectColumn
    , inFlight : GitHubGraph.ProjectColumn
    , done : GitHubGraph.ProjectColumn
    }


selectStatefulProject : GitHubGraph.Project -> Maybe ProjectState
selectStatefulProject project =
    let
        findColumns match =
            List.filter (match << .name) project.columns

        icebox =
            findColumns detectColumn.icebox

        backlogs =
            findColumns detectColumn.backlog

        inFlights =
            findColumns detectColumn.inFlight

        dones =
            findColumns detectColumn.done
    in
    case ( backlogs, ( icebox, inFlights, dones ) ) of
        ( (_ :: _) as bs, ( [ ib ], [ i ], [ d ] ) ) ->
            Just
                { project = project
                , icebox = ib
                , backlogs = bs
                , inFlight = i
                , done = d
                }

        _ ->
            Nothing


viewAllProjectsPage : Model -> Html Msg
viewAllProjectsPage model =
    let
        statefulProjects =
            List.filterMap selectStatefulProject (Dict.values model.data.projects)
    in
    Html.div [ HA.class "project-table" ]
        [ Html.div [ HA.class "projects" ]
            (List.map (viewProject model) statefulProjects)
        ]


viewLabelsPage : Model -> Html Msg
viewLabelsPage model =
    let
        newLabel =
            Html.div [ HA.class "label-row" ]
                [ Html.div [ HA.class "label-cell" ]
                    [ Html.div [ HA.class "label-name" ]
                        [ Html.form [ HA.class "label-edit", HE.onSubmit CreateLabel ]
                            [ Html.span
                                ([ HA.class "label-icon label-color-control octicon octicon-sync"
                                 , HE.onClick RandomizeNewLabelColor
                                 ]
                                    ++ labelColorStyles model model.newLabel.color
                                )
                                []
                            , Html.input
                                ([ HE.onInput SetNewLabelName
                                 , HA.value model.newLabel.name
                                 ]
                                    ++ labelColorStyles model model.newLabel.color
                                )
                                []
                            ]
                        ]
                    ]
                , Html.div [ HA.class "label-cell" ]
                    [ Html.div [ HA.class "label-controls" ]
                        [ Html.span
                            [ HE.onClick CreateLabel
                            , HA.class "button octicon octicon-plus"
                            ]
                            []
                        ]
                    ]
                , Html.div [ HA.class "label-cell" ]
                    [ Html.div [ HA.class "label-counts first" ]
                        []
                    ]
                , Html.div [ HA.class "label-cell" ]
                    [ Html.div [ HA.class "label-counts" ]
                        []
                    ]
                , Html.div [ HA.class "label-cell" ]
                    [ Html.div [ HA.class "label-counts last" ]
                        []
                    ]
                ]

        labelRows =
            (\a -> List.map a (Dict.toList model.dataView.reposByLabel)) <|
                \( ( name, color ), repos ) ->
                    viewLabelRow model { name = name, color = color } repos
    in
    Html.div [ HA.class "all-labels" ]
        (newLabel :: labelRows)


viewShipItPage : Model -> Html Msg
viewShipItPage model =
    let
        repos =
            Dict.values model.dataView.shipItRepos
                |> List.sortBy (.totalCommits << .comparison)
                |> List.reverse
    in
    Html.div [ HA.class "shipit-page" ]
        (List.map (viewShipItRepo model) repos)


viewShipItRepoPage : Model -> ShipItRepo -> Html Msg
viewShipItRepoPage model sir =
    Html.div [ HA.class "shipit-repo-content" ]
        [ Html.div [ HA.class "shipit-header" ]
            [ Html.div [ HA.class "repo-name-label" ]
                [ octicon "repo"
                , Html.a [ HA.href "/shipit" ] [ Html.text sir.repo.owner ]
                , Html.text " / "
                , Html.span [ HA.style "font-weight" "bold" ] [ Html.text sir.repo.name ]
                ]
            , case sir.nextMilestone of
                Just nm ->
                    Html.div [ HA.class "repo-milestone-label" ]
                        [ octicon "milestone"
                        , Html.text nm.title
                        ]

                Nothing ->
                    Html.text ""
            ]
        , Html.div [ HA.class "shipit-repo-tabview" ]
            [ let
                tabAttrs tab =
                    [ HA.classList [ ( "shipit-repo-tab", True ), ( "selected", model.shipItRepoTab == tab ) ]
                    , HE.onClick (SetShipItRepoTab tab)
                    ]

                tabCount count =
                    Html.span [ HA.class "counter" ]
                        [ Html.text (String.fromInt count) ]
              in
              Html.div [ HA.class "shipit-repo-tabs" ]
                [ Html.span (tabAttrs ToDoTab)
                    [ Html.text "To Do"
                    , tabCount (List.length sir.openIssues + List.length sir.openPRs)
                    ]
                , Html.span (tabAttrs UndocumentedTab)
                    [ Html.text "Done"
                    , tabCount (List.length sir.undocumentedCards)
                    ]
                , Html.span (tabAttrs DocumentedTab)
                    [ Html.text "Documented"
                    , tabCount (List.length sir.documentedCards)
                    ]
                , Html.span (tabAttrs LeftUndocumentedTab)
                    [ Html.text "Undocumented"
                    , tabCount (List.length sir.leftUndocumentedCards)
                    ]
                , Html.span (tabAttrs UnreleasedTab)
                    [ Html.text "Unreleased"
                    , tabCount (List.length sir.unreleasedCards)
                    ]
                ]
            ]
        , Html.div
            [ HA.classList
                [ ( "shipit-repo-cards", True )
                , ( "first-tab", model.shipItRepoTab == ToDoTab )
                ]
            ]
          <|
            let
                cards =
                    case model.shipItRepoTab of
                        ToDoTab ->
                            sir.openIssues ++ sir.openPRs

                        UndocumentedTab ->
                            sir.undocumentedCards

                        DocumentedTab ->
                            sir.documentedCards

                        LeftUndocumentedTab ->
                            sir.leftUndocumentedCards

                        UnreleasedTab ->
                            sir.unreleasedCards
            in
            cards
                |> List.sortBy (.updatedAt >> Time.posixToMillis)
                |> List.reverse
                |> List.map (viewCard model)
        ]


viewShipItRepo : Model -> ShipItRepo -> Html Msg
viewShipItRepo model sir =
    Html.div [ HA.class "shipit-repo" ]
        [ Html.div [ HA.class "repo-name" ]
            [ Html.div [ HA.class "repo-name-label" ]
                [ octicon "repo"
                , Html.a
                    [ HA.href ("/shipit/" ++ sir.repo.name)
                    ]
                    [ Html.text sir.repo.name ]
                ]
            ]
        , Html.div [ HA.class "shipit-metric shipit-metric-commits" ]
            [ octicon "git-commit"
            , Html.text (String.fromInt sir.comparison.totalCommits ++ " commits since last release")
            ]
        , Html.div [ HA.class "shipit-metric shipit-metric-merged-prs" ]
            [ octicon "git-pull-request"
            , Html.text (String.fromInt (List.length sir.mergedPRs) ++ " merged pull requests")
            ]
        , if List.isEmpty sir.closedIssues then
            Html.text ""

          else
            Html.div [ HA.class "shipit-metric shipit-metric-closed-issues" ]
                [ octicon "issue-closed"
                , Html.text (String.fromInt (List.length sir.closedIssues) ++ " closed issues")
                ]
        , if List.isEmpty sir.openIssues then
            Html.text ""

          else
            Html.div [ HA.class "shipit-metric shipit-metric-open-issues" ]
                [ octicon "issue-opened"
                , Html.text (String.fromInt (List.length sir.openIssues) ++ " open issues")
                ]
        ]


viewPullRequestsPage : Model -> Html Msg
viewPullRequestsPage model =
    let
        getRepo repoId prs acc =
            case Dict.get repoId model.data.repos of
                Just repo ->
                    ( repo, prs ) :: acc

                Nothing ->
                    acc

        viewRepoPRs repo prs =
            Html.div [ HA.class "repo-pull-requests" ]
                [ Html.div [ HA.class "repo-name" ]
                    [ Html.div [ HA.class "repo-name-label" ]
                        [ octicon "repo"
                        , Html.text repo.name
                        ]
                    ]
                , Html.div [ HA.class "cards" ]
                    (List.map (viewCard model) prs)
                ]
    in
    Html.div [ HA.class "all-pull-requests" ]
        (Dict.foldl getRepo [] model.dataView.prsByRepo
            |> List.sortBy (Tuple.second >> List.length)
            |> List.reverse
            |> List.map (\( a, b ) -> viewRepoPRs a b)
        )


matchesLabel : SharedLabel -> GitHubGraph.Label -> Bool
matchesLabel sl l =
    l.name == sl.name && String.toLower l.color == String.toLower sl.color


includesLabel : Model -> SharedLabel -> List GitHubGraph.ID -> Bool
includesLabel model label labelIds =
    List.any
        (\id ->
            case Dict.get id model.allLabels of
                Just l ->
                    matchesLabel label l

                Nothing ->
                    False
        )
        labelIds


viewLabelRow : Model -> SharedLabel -> List GitHubGraph.Repo -> Html Msg
viewLabelRow model label repos =
    let
        stateKey =
            labelKey label

        ( prs, issues ) =
            Dict.foldl
                (\_ c ( ps, is ) ->
                    if isOpen c && includesLabel model label c.labels then
                        if isPR c then
                            ( c :: ps, is )

                        else
                            ( ps, c :: is )

                    else
                        ( ps, is )
                )
                ( [], [] )
                model.allCards
    in
    Html.div [ HA.class "label-row" ]
        [ Html.div [ HA.class "label-cell" ]
            [ Html.div [ HA.class "label-name" ]
                [ case Dict.get stateKey model.editingLabels of
                    Nothing ->
                        Html.div [ HA.class "label-background" ]
                            [ if String.isEmpty model.newLabel.name && Dict.isEmpty model.editingLabels then
                                Html.span
                                    ([ HA.class "label-icon octicon octicon-tag"
                                     , HE.onClick (searchLabel model label.name)
                                     ]
                                        ++ labelColorStyles model label.color
                                    )
                                    []

                              else
                                Html.span
                                    ([ HA.class "label-icon label-color-control octicon octicon-paintcan"
                                     , HE.onClick (SetLabelColor label.color)
                                     ]
                                        ++ labelColorStyles model label.color
                                    )
                                    []
                            , Html.span
                                ([ HA.class "label big"
                                 , HE.onClick (searchLabel model label.name)
                                 ]
                                    ++ labelColorStyles model label.color
                                )
                                [ Html.span [ HA.class "label-text" ]
                                    [ Html.text label.name ]
                                ]
                            ]

                    Just newLabel ->
                        Html.form [ HA.class "label-edit", HE.onSubmit (EditLabel label) ]
                            [ Html.span
                                ([ HA.class "label-icon label-color-control octicon octicon-sync"
                                 , HE.onClick (RandomizeLabelColor label)
                                 ]
                                    ++ labelColorStyles model newLabel.color
                                )
                                []
                            , Html.input
                                ([ HE.onInput (SetLabelName label)
                                 , HA.value newLabel.name
                                 ]
                                    ++ labelColorStyles model newLabel.color
                                )
                                []
                            ]
                ]
            ]
        , Html.div [ HA.class "label-cell" ]
            [ Html.div [ HA.class "label-counts first" ]
                [ Html.span [ HA.class "count" ]
                    [ octicon "issue-opened"
                    , Html.span [ HA.class "count-number" ]
                        [ Html.text (String.fromInt (List.length issues))
                        ]
                    ]
                ]
            ]
        , Html.div [ HA.class "label-cell" ]
            [ Html.div [ HA.class "label-counts" ]
                [ Html.span [ HA.class "count" ]
                    [ octicon "git-pull-request"
                    , Html.span [ HA.class "count-number" ]
                        [ Html.text (String.fromInt (List.length prs))
                        ]
                    ]
                ]
            ]
        , Html.div [ HA.class "label-cell" ]
            [ Html.div [ HA.class "label-counts last" ]
                [ Html.span [ HA.class "count", HA.title (String.join ", " (List.map .name repos)) ]
                    [ octicon "repo"
                    , Html.span [ HA.class "count-number" ]
                        [ Html.text (String.fromInt (List.length repos))
                        ]
                    ]
                ]
            ]
        , Html.div [ HA.class "label-cell drawer-cell" ]
            [ Html.div [ HA.class "label-controls" ]
                [ Html.span
                    [ HE.onClick (MirrorLabel label)
                    , HA.class "button octicon octicon-mirror"
                    ]
                    []
                , if Dict.member stateKey model.editingLabels then
                    Html.span
                        [ HE.onClick (StopEditingLabel label)
                        , HA.class "button octicon octicon-x"
                        ]
                        []

                  else
                    Html.span
                        [ HE.onClick (StartEditingLabel label)
                        , HA.class "button octicon octicon-pencil"
                        ]
                        []
                , if Set.member stateKey model.deletingLabels then
                    Html.span
                        [ HE.onClick (StopDeletingLabel label)
                        , HA.class "button close octicon octicon-x"
                        ]
                        []

                  else
                    Html.span
                        [ HE.onClick (StartDeletingLabel label)
                        , HA.class "button octicon octicon-trashcan"
                        ]
                        []
                ]
            , let
                isDeleting =
                    Set.member stateKey model.deletingLabels

                isEditing =
                    Dict.member stateKey model.editingLabels
              in
              Html.div
                [ HA.classList
                    [ ( "label-confirm", True )
                    , ( "active", isDeleting || isEditing )
                    ]
                ]
                [ if isDeleting then
                    Html.span
                        [ HE.onClick (DeleteLabel label)
                        , HA.class "button delete octicon octicon-check"
                        ]
                        []

                  else
                    Html.span
                        [ HE.onClick (EditLabel label)
                        , HA.class "button edit octicon octicon-check"
                        ]
                        []
                ]
            ]
        ]


searchLabel : Model -> String -> Msg
searchLabel model name =
    SearchCards <|
        if String.isEmpty model.cardSearch then
            "label:" ++ name

        else
            model.cardSearch ++ " label:" ++ name


labelColorStyles : Model -> String -> List (Html.Attribute Msg)
labelColorStyles model color =
    [ HA.style "background-color" ("#" ++ color)
    , HA.style "color" <|
        if colorIsLight model color then
            -- GitHub appears to pre-compute a hex code, but this seems to be
            -- pretty much all it's doing
            "rgba(0, 0, 0, .8)"

        else
            -- for darker backgrounds they just do white
            "#fff"
    ]


onlyOpenCards : Model -> List Backend.ColumnCard -> List Backend.ColumnCard
onlyOpenCards model =
    List.filter <|
        \{ contentId } ->
            case contentId of
                Just id ->
                    case Dict.get id model.allCards of
                        Just card ->
                            isOpen card

                        Nothing ->
                            False

                Nothing ->
                    False


viewProject : Model -> ProjectState -> Html Msg
viewProject model { project, backlogs, inFlight, done } =
    Html.div [ HA.class "project" ]
        [ Html.div [ HA.class "project-columns" ]
            [ Html.div [ HA.class "column name-column" ]
                [ Html.h4 []
                    [ Html.a
                        [ HA.href ("/projects/" ++ project.name)
                        ]
                        [ Html.text project.name ]
                    ]
                ]
            , Html.div [ HA.class "column backlog-column" ]
                (List.map (\backlog -> viewProjectColumn model project (List.take 3) backlog) backlogs)
            , Html.div [ HA.class "column in-flight-column" ]
                [ viewProjectColumn model project identity inFlight ]
            , Html.div [ HA.class "column done-column" ]
                [ viewProjectColumn model project (onlyOpenCards model) done ]
            ]
        ]


viewProjectColumn : Model -> GitHubGraph.Project -> (List Backend.ColumnCard -> List Backend.ColumnCard) -> GitHubGraph.ProjectColumn -> Html Msg
viewProjectColumn model project mod col =
    let
        cards =
            mod <|
                Maybe.withDefault [] (Dict.get col.id model.data.columnCards)

        dropCandidate =
            { msgFunc = MoveCardAfter
            , target =
                { projectId = project.id
                , columnId = col.id
                , afterId = Nothing
                }
            }
    in
    Html.div [ HA.class "project-column" ]
        [ Html.div [ HA.class "column-name" ]
            [ Html.a [ HA.href ("/projects/" ++ project.name) ] [ Html.text col.name ]
            ]
        , if List.isEmpty cards then
            Html.div [ HA.class "no-cards" ]
                [ Drag.viewDropArea model.projectDrag ProjectDrag dropCandidate Nothing
                ]

          else
            Html.div [ HA.class "cards" ] <|
                Drag.viewDropArea model.projectDrag ProjectDrag dropCandidate Nothing
                    :: List.concatMap (viewProjectColumnCard model project col) cards
        ]


viewProjectColumnCard : Model -> GitHubGraph.Project -> GitHubGraph.ProjectColumn -> Backend.ColumnCard -> List (Html Msg)
viewProjectColumnCard model project col ghCard =
    let
        dragId =
            FromColumnCardSource { columnId = col.id, cardId = ghCard.id }

        dropCandidate =
            { msgFunc = MoveCardAfter
            , target =
                { projectId = project.id
                , columnId = col.id
                , afterId = Just ghCard.id
                }
            }
    in
    case ( ghCard.note, ghCard.contentId ) of
        ( Just n, Nothing ) ->
            [ Drag.draggable model.projectDrag ProjectDrag dragId (viewNoteCard model col n)
            , Drag.viewDropArea model.projectDrag ProjectDrag dropCandidate (Just dragId)
            ]

        ( Nothing, Just contentId ) ->
            case Dict.get contentId model.allCards of
                Just card ->
                    [ Drag.draggable model.projectDrag ProjectDrag dragId (viewCard model card)
                    , Drag.viewDropArea model.projectDrag ProjectDrag dropCandidate (Just dragId)
                    ]

                Nothing ->
                    Log.debug "impossible: content has no card" contentId <|
                        []

        _ ->
            Log.debug "impossible?: card has no note or content" ghCard <|
                []


viewProjectPage : Model -> String -> Html Msg
viewProjectPage model name =
    let
        statefulProjects =
            List.filterMap selectStatefulProject (Dict.values model.data.projects)

        mproject =
            List.head <|
                List.filter ((==) name << .name << .project) statefulProjects
    in
    case mproject of
        Just project ->
            viewSingleProject model project

        Nothing ->
            Html.text "project not found"


viewSingleProject : Model -> ProjectState -> Html Msg
viewSingleProject model { project, icebox, backlogs, inFlight, done } =
    Html.div [ HA.class "project single" ]
        [ Html.div [ HA.class "project-columns" ]
            ([ Html.div [ HA.class "column name-column" ]
                [ Html.h4 [] [ Html.text project.name ] ]
             , Html.div [ HA.class "column done-column" ]
                [ viewProjectColumn model project (onlyOpenCards model) done ]
             , Html.div [ HA.class "column in-flight-column" ]
                [ viewProjectColumn model project identity inFlight ]
             ]
                ++ List.map
                    (\backlog ->
                        Html.div [ HA.class "column backlog-column" ]
                            [ viewProjectColumn model project identity backlog ]
                    )
                    backlogs
            )
        , Html.div [ HA.class "icebox-graph" ]
            [ viewSpatialGraph model
            , let
                dropCandidate =
                    { msgFunc = MoveCardAfter
                    , target =
                        { projectId = project.id
                        , columnId = icebox.id
                        , afterId = Nothing
                        }
                    }
              in
              Drag.viewDropArea model.projectDrag ProjectDrag dropCandidate Nothing
            ]
        ]


viewSearch : Model -> Html Msg
viewSearch model =
    Html.div [ HA.class "card-search" ]
        [ Html.form [ HE.onSubmit SelectAnticipatedCards ]
            [ Html.input
                [ HA.type_ "search"
                , HA.placeholder "search cards"
                , HA.value model.cardSearch
                , HE.onInput SearchCards
                ]
                []
            ]
        ]


computeGraph : Model -> Model
computeGraph model =
    let
        cardEdges =
            Dict.foldl
                (\idStr sourceIds refs ->
                    let
                        id =
                            Hash.hash idStr
                    in
                    List.map
                        (\sourceId ->
                            { from = Hash.hash sourceId
                            , to = id
                            , label = ()
                            }
                        )
                        sourceIds
                        ++ refs
                )
                []
                model.data.references

        allFilters =
            case model.baseGraphFilter of
                Just f ->
                    f :: model.graphFilters

                Nothing ->
                    model.graphFilters

        node card context =
            { value = cardNode model card context
            , size = cardRadiusBase card context
            }

        cardNodeThunks =
            Dict.foldl
                (\_ card thunks ->
                    if satisfiesFilters model allFilters card && isOpen card then
                        Graph.Node (Hash.hash card.id) (node card) :: thunks

                    else
                        thunks
                )
                []
                model.allCards

        applyWithContext nc =
            { node = { id = nc.node.id, label = nc.node.label { incoming = nc.incoming, outgoing = nc.outgoing } }
            , incoming = nc.incoming
            , outgoing = nc.outgoing
            }

        graph =
            Graph.mapContexts applyWithContext <|
                Graph.fromNodesAndEdges
                    cardNodeThunks
                    cardEdges

        sortFunc =
            case model.graphSort of
                ImpactSort ->
                    graphSizeCompare

                UserActivitySort login ->
                    graphUserActivityCompare model login

                AllActivitySort ->
                    graphAllActivityCompare model

        baseState =
            baseGraphState model
    in
    { model
        | cardGraphs =
            subGraphs graph
                |> List.map FG.fromGraph
                |> List.sortWith sortFunc
                |> List.reverse
                |> List.map (\g -> ( baseState, g ))
    }


baseGraphState : Model -> CardNodeState
baseGraphState model =
    { currentTime = model.currentTime
    , me = model.me
    , dataIndex = model.dataIndex
    , cardEvents = model.data.actors
    , selectedCards = OrderedSet.empty
    , anticipatedCards = Set.empty
    , highlightedNode = Nothing
    }


isBaseGraphState : Model -> CardNodeState -> Bool
isBaseGraphState model state =
    (state.currentTime == model.currentTime)
        && (state.me == model.me)
        && (state.dataIndex == model.dataIndex)
        && Set.isEmpty state.anticipatedCards
        && OrderedSet.isEmpty state.selectedCards
        && (state.highlightedNode == Nothing)


satisfiesFilters : Model -> List GraphFilter -> Card -> Bool
satisfiesFilters model filters card =
    List.all (\a -> satisfiesFilter model a card) filters


satisfiesFilter : Model -> GraphFilter -> Card -> Bool
satisfiesFilter model filter card =
    case filter of
        ExcludeAllFilter ->
            False

        InProjectFilter name ->
            isInProject name card

        HasLabelFilter label color ->
            hasLabelAndColor model label color card

        InvolvesUserFilter login ->
            involvesUser model login card

        PullRequestsFilter ->
            isPR card

        IssuesFilter ->
            not (isPR card)

        UntriagedFilter ->
            isUntriaged card


graphSizeCompare : ForceGraph (Node a) -> ForceGraph (Node a) -> Order
graphSizeCompare a b =
    case compare (Graph.size a.graph) (Graph.size b.graph) of
        EQ ->
            let
                graphScore =
                    List.foldl (+) 0 << List.map (.label >> .value >> .score) << Graph.nodes
            in
            compare (graphScore a.graph) (graphScore b.graph)

        x ->
            x


graphUserActivityCompare : Model -> String -> ForceGraph (Node a) -> ForceGraph (Node a) -> Order
graphUserActivityCompare model login a b =
    let
        latestUserActivity g =
            Graph.nodes g
                |> List.map
                    (\n ->
                        Maybe.withDefault [] (Dict.get n.label.value.card.id model.data.actors)
                            |> List.reverse
                            |> List.filter (.user >> Maybe.map .login >> (==) (Just login))
                            |> List.map (.createdAt >> Time.posixToMillis)
                            |> List.head
                            |> Maybe.withDefault 0
                    )
                |> List.maximum
                |> Maybe.withDefault 0
    in
    compare (latestUserActivity a.graph) (latestUserActivity b.graph)


graphAllActivityCompare : Model -> ForceGraph (Node a) -> ForceGraph (Node a) -> Order
graphAllActivityCompare model a b =
    let
        latestActivity g =
            Graph.nodes g
                |> List.map
                    (\n ->
                        Maybe.withDefault [] (Dict.get n.label.value.card.id model.data.actors)
                            |> List.reverse
                            |> List.map .createdAt
                            |> List.head
                            |> Maybe.withDefault n.label.value.card.updatedAt
                            |> Time.posixToMillis
                    )
                |> List.maximum
                |> Maybe.withDefault 0
    in
    compare (latestActivity a.graph) (latestActivity b.graph)


viewGraph : CardNodeState -> ForceGraph (Node CardNodeState) -> Html Msg
viewGraph state { graph } =
    let
        nodeContexts =
            Graph.fold (::) [] graph

        bounds =
            List.map nodeBounds nodeContexts

        padding =
            10

        minX =
            List.foldl (\{ x1 } acc -> min x1 acc) 999999 bounds - padding

        minY =
            List.foldl (\{ y1 } acc -> min y1 acc) 999999 bounds - padding

        maxX =
            List.foldl (\{ x2 } acc -> max x2 acc) 0 bounds + padding

        maxY =
            List.foldl (\{ y2 } acc -> max y2 acc) 0 bounds + padding

        width =
            maxX - minX

        height =
            maxY - minY

        links =
            List.map (Svg.Lazy.lazy2 linkPath graph) (Graph.edges graph)

        ( flairs, nodes ) =
            Graph.fold (viewNodeLowerUpper state) ( [], [] ) graph
    in
    Svg.svg
        [ SA.width (String.fromFloat width ++ "px")
        , SA.height (String.fromFloat height ++ "px")
        , SA.viewBox (String.fromFloat minX ++ " " ++ String.fromFloat minY ++ " " ++ String.fromFloat width ++ " " ++ String.fromFloat height)
        ]
        [ Svg.g [ SA.class "lower" ] flairs
        , Svg.g [ SA.class "links" ] links
        , Svg.g [ SA.class "upper" ] nodes
        ]


viewNodeLowerUpper : CardNodeState -> Graph.NodeContext (FG.ForceNode (Node CardNodeState)) () -> ( List (Svg Msg), List (Svg Msg) ) -> ( List (Svg Msg), List (Svg Msg) )
viewNodeLowerUpper state { node } ( fs, ns ) =
    let
        pos =
            { x = node.label.x, y = node.label.y }
    in
    ( Svg.Lazy.lazy2 node.label.value.viewLower pos state :: fs
    , Svg.Lazy.lazy2 node.label.value.viewUpper pos state :: ns
    )


linkPath : Graph (FG.ForceNode n) () -> Graph.Edge () -> Svg Msg
linkPath graph edge =
    let
        source =
            case Maybe.map (.node >> .label) (Graph.get edge.from graph) of
                Just { x, y } ->
                    { x = x, y = y }

                Nothing ->
                    { x = 0, y = 0 }

        target =
            case Maybe.map (.node >> .label) (Graph.get edge.to graph) of
                Just { x, y } ->
                    { x = x, y = y }

                Nothing ->
                    { x = 0, y = 0 }
    in
    Svg.line
        [ SA.class "graph-edge"
        , SA.x1 (String.fromFloat source.x)
        , SA.y1 (String.fromFloat source.y)
        , SA.x2 (String.fromFloat target.x)
        , SA.y2 (String.fromFloat target.y)
        ]
        []


type alias GraphContext =
    { incoming : IntDict ()
    , outgoing : IntDict ()
    }


cardRadiusBase : Card -> GraphContext -> Float
cardRadiusBase card { incoming, outgoing } =
    -- trust me
    10
        + (6 * toFloat (floor (logBase 10 (toFloat card.number))))
        + ((toFloat (IntDict.size incoming) / 2) + toFloat (IntDict.size outgoing * 2))


cardRadiusWithLabels : Card -> GraphContext -> Float
cardRadiusWithLabels card context =
    cardRadiusBase card context + 3


cardRadiusWithoutFlair : Card -> GraphContext -> Float
cardRadiusWithoutFlair card context =
    cardRadiusWithLabels card context


flairRadiusBase : Float
flairRadiusBase =
    20


cardRadiusWithFlair : Card -> GraphContext -> Float
cardRadiusWithFlair card context =
    let
        reactionCounts =
            List.map .count card.reactions

        highestFlair =
            List.foldl (\num acc -> max num acc) 0 (card.commentCount :: reactionCounts)
    in
    cardRadiusWithoutFlair card context + flairRadiusBase + toFloat highestFlair


cardNode : Model -> Card -> GraphContext -> Node CardNodeState
cardNode model card context =
    let
        flairArcs =
            reactionFlairArcs (Maybe.withDefault [] <| Dict.get card.id model.data.reviewers) card context

        labelArcs =
            cardLabelArcs model.allLabels card context

        circle =
            Svg.g []
                [ Svg.circle
                    [ SA.r (String.fromFloat radii.base)
                    , SA.fill "#fff"
                    ]
                    []
                , Svg.text_
                    [ SA.textAnchor "middle"
                    , SA.alignmentBaseline "middle"
                    , SA.class "issue-number"
                    ]
                    [ Svg.text ("#" ++ String.fromInt card.number)
                    ]
                ]

        radii =
            { base = cardRadiusBase card context
            , withoutFlair = cardRadiusWithoutFlair card context
            , withFlair = cardRadiusWithFlair card context
            }
    in
    { card = card
    , viewLower = viewCardNodeFlair card radii flairArcs
    , viewUpper = viewCardNode card radii circle labelArcs
    , bounds =
        \{ x, y } ->
            { x1 = x - radii.withFlair
            , y1 = y - radii.withFlair
            , x2 = x + radii.withFlair
            , y2 = y + radii.withFlair
            }
    , score = card.score
    }


reactionFlairArcs : List GitHubGraph.PullRequestReview -> Card -> GraphContext -> List (Svg Msg)
reactionFlairArcs reviews card context =
    let
        radius =
            cardRadiusWithoutFlair card context

        reactionTypeEmoji type_ =
            case type_ of
                GitHubGraph.ReactionTypeThumbsUp ->
                    "👍"

                GitHubGraph.ReactionTypeThumbsDown ->
                    "👎"

                GitHubGraph.ReactionTypeLaugh ->
                    "😄"

                GitHubGraph.ReactionTypeConfused ->
                    "😕"

                GitHubGraph.ReactionTypeHeart ->
                    "💖"

                GitHubGraph.ReactionTypeHooray ->
                    "🎉"

                GitHubGraph.ReactionTypeRocket ->
                    "🚀"

                GitHubGraph.ReactionTypeEyes ->
                    "👀"

        emojiReactions =
            (\a -> List.map a card.reactions) <|
                \{ type_, count } ->
                    ( Html.text (reactionTypeEmoji type_), "reaction", count )

        prSegments =
            case card.content of
                GitHubGraph.IssueCardContent _ ->
                    []

                GitHubGraph.PullRequestCardContent pr ->
                    let
                        statusChecks =
                            case Maybe.map .status pr.lastCommit of
                                Just (Just { contexts }) ->
                                    (\a -> List.map a contexts) <|
                                        \c ->
                                            ( Html.span
                                                [ HA.classList
                                                    [ ( "status-icon", True )
                                                    , ( "octicon", True )
                                                    , ( case c.state of
                                                            GitHubGraph.StatusStatePending ->
                                                                "octicon-primitive-dot"

                                                            GitHubGraph.StatusStateSuccess ->
                                                                "octicon-check"

                                                            GitHubGraph.StatusStateFailure ->
                                                                "octicon-x"

                                                            GitHubGraph.StatusStateExpected ->
                                                                "octicon-question"

                                                            GitHubGraph.StatusStateError ->
                                                                "octicon-alert"
                                                      , True
                                                      )
                                                    ]
                                                ]
                                                []
                                            , case c.state of
                                                GitHubGraph.StatusStatePending ->
                                                    "pending"

                                                GitHubGraph.StatusStateSuccess ->
                                                    "success"

                                                GitHubGraph.StatusStateFailure ->
                                                    "failure"

                                                GitHubGraph.StatusStateExpected ->
                                                    "expected"

                                                GitHubGraph.StatusStateError ->
                                                    "error"
                                            , 0
                                            )

                                _ ->
                                    []

                        reviewStates =
                            List.map
                                (\r ->
                                    ( Html.img [ HA.class "status-actor", HA.src r.author.avatar ] []
                                    , case r.state of
                                        GitHubGraph.PullRequestReviewStatePending ->
                                            "pending"

                                        GitHubGraph.PullRequestReviewStateApproved ->
                                            "success"

                                        GitHubGraph.PullRequestReviewStateChangesRequested ->
                                            "failure"

                                        GitHubGraph.PullRequestReviewStateCommented ->
                                            "commented"

                                        GitHubGraph.PullRequestReviewStateDismissed ->
                                            "dismissed"
                                    , 0
                                    )
                                )
                                reviews
                    in
                    ( Html.span [ HA.class "status-icon octicon octicon-git-merge" ] []
                    , case pr.mergeable of
                        GitHubGraph.MergeableStateMergeable ->
                            "success"

                        GitHubGraph.MergeableStateConflicting ->
                            "failure"

                        GitHubGraph.MergeableStateUnknown ->
                            "pending"
                    , 0
                    )
                        :: (statusChecks ++ reviewStates)

        flairs =
            prSegments
                ++ (List.filter (\( _, _, count ) -> count > 0) <|
                        (( octicon "comment", "comments", card.commentCount ) :: emojiReactions)
                   )

        segments =
            Shape.pie
                { startAngle = 0
                , endAngle = 2 * pi
                , padAngle = 0.03
                , sortingFn = Basics.compare
                , valueFn = identity
                , innerRadius = radius
                , outerRadius = radius + flairRadiusBase
                , cornerRadius = 3
                , padRadius = 0
                }
                (List.repeat (List.length flairs) 1)

        reactionSegment i ( _, _, count ) =
            case List.take 1 (List.drop i segments) of
                [ s ] ->
                    s

                _ ->
                    Log.debug "impossible: empty segments"
                        ( i, segments )
                        emptyArc
    in
    (\a -> List.indexedMap a flairs) <|
        \i (( content, class, count ) as reaction) ->
            let
                segmentArc =
                    reactionSegment i reaction

                arc =
                    { segmentArc | outerRadius = segmentArc.outerRadius + toFloat count }

                ( centroidX, centroidY ) =
                    let
                        r =
                            arc.innerRadius + 12

                        a =
                            (arc.startAngle + arc.endAngle) / 2 - pi / 2
                    in
                    ( cos a * r - 8, sin a * r - 8 )
            in
            Svg.g [ SA.class "reveal" ]
                [ Path.element (Shape.arc arc)
                    [ SA.class ("flair-arc " ++ class)
                    ]
                , Svg.foreignObject
                    [ SA.transform ("translate(" ++ String.fromFloat centroidX ++ "," ++ String.fromFloat centroidY ++ ")")
                    , SA.class "hidden"
                    ]
                    [ content
                    ]
                ]


cardLabelArcs : Dict GitHubGraph.ID GitHubGraph.Label -> Card -> GraphContext -> List (Svg Msg)
cardLabelArcs allLabels card context =
    let
        radius =
            cardRadiusBase card context

        labelSegments =
            Shape.pie
                { startAngle = 0
                , endAngle = 2 * pi
                , padAngle = 0
                , sortingFn = \_ _ -> EQ
                , valueFn = always 1.0
                , innerRadius = radius
                , outerRadius = radius + 3
                , cornerRadius = 0
                , padRadius = 0
                }
                (List.repeat (List.length card.labels) 1)
    in
    List.map2
        (\arc label ->
            Path.element (Shape.arc arc)
                [ SA.fill ("#" ++ label.color)
                , SA.class "label-arc"
                ]
        )
        labelSegments
        (List.filterMap (\a -> Dict.get a allLabels) card.labels)


viewCardNodeFlair : Card -> CardNodeRadii -> List (Svg Msg) -> Position -> CardNodeState -> Svg Msg
viewCardNodeFlair card radii flair { x, y } state =
    let
        isHighlighted =
            Set.member card.id state.anticipatedCards
                || (state.highlightedNode == Just card.id)

        scale =
            if isHighlighted then
                "1.1"

            else
                "1"

        anticipateRadius =
            if List.isEmpty card.labels then
                radii.base + 5

            else
                radii.withoutFlair + 5

        anticipatedHalo =
            if isHighlighted then
                Svg.circle
                    [ SA.r (String.fromFloat anticipateRadius)
                    , SA.class "anticipated-circle"
                    ]
                    []

            else
                Svg.text ""

        classes =
            [ "flair", activityClass state.currentTime card.updatedAt ]
                ++ (case state.me of
                        Nothing ->
                            []

                        Just { user } ->
                            if lastActivityIsByUser state.cardEvents user.login card then
                                [ "last-activity-is-me" ]

                            else
                                []
                   )
    in
    Svg.g
        [ SA.transform ("translate(" ++ String.fromFloat x ++ "," ++ String.fromFloat y ++ ") scale(" ++ scale ++ ")")
        , SA.class (String.join " " classes)
        ]
        (flair ++ [ anticipatedHalo ])


activityClass : Time.Posix -> Time.Posix -> String
activityClass now date =
    let
        delta =
            Time.posixToMillis now - Time.posixToMillis date

        daysSinceLastUpdate =
            delta // (24 * 60 * 60 * 1000)
    in
    if daysSinceLastUpdate <= 1 then
        "active-today"

    else if daysSinceLastUpdate <= 2 then
        "active-yesterday"

    else if daysSinceLastUpdate <= 7 then
        "active-this-week"

    else if daysSinceLastUpdate <= 30 then
        "active-this-month"

    else
        "active-long-ago"


viewCardNode : Card -> CardNodeRadii -> Svg Msg -> List (Svg Msg) -> Position -> CardNodeState -> Svg Msg
viewCardNode card radii circle labels { x, y } state =
    let
        isSelected =
            OrderedSet.member card.id state.selectedCards

        isHighlighted =
            Set.member card.id state.anticipatedCards
                || (state.highlightedNode == Just card.id)

        projectHalo =
            Svg.circle
                [ SA.strokeWidth "3px"
                , SA.r (String.fromFloat (radii.base - 1.5))
                , if isInFlight card then
                    SA.class "project-status in-flight"

                  else if isDone card then
                    SA.class "project-status done"

                  else if isIcebox card then
                    SA.class "project-status icebox"

                  else if isBacklog card then
                    SA.class "project-status backlog"

                  else
                    SA.class "project-status untriaged"
                ]
                []

        scale =
            if isHighlighted then
                "1.1"

            else
                "1"
    in
    Svg.g
        [ SA.transform ("translate(" ++ String.fromFloat x ++ "," ++ String.fromFloat y ++ ") scale(" ++ scale ++ ")")
        , if isInFlight card then
            SA.class "in-flight"

          else if isDone card then
            SA.class "done"

          else if isIcebox card then
            SA.class "icebox"

          else if isBacklog card then
            SA.class "backlog"

          else
            SA.class "untriaged"
        , SE.onMouseOver (AnticipateCardFromNode card.id)
        , SE.onMouseOut (UnanticipateCardFromNode card.id)
        , SE.onClick
            (if isSelected then
                DeselectCard card.id

             else
                SelectCard card.id
            )
        ]
        (circle :: labels ++ [ projectHalo ])


viewCardEntry : Model -> Card -> Html Msg
viewCardEntry model card =
    let
        anticipated =
            isAnticipated model card

        cardView =
            viewCard model card

        dragSource =
            NewContentCardSource { contentId = card.id }
    in
    Html.div [ HA.class "card-controls" ]
        [ Drag.draggable model.projectDrag ProjectDrag dragSource <|
            cardView
        , Html.div [ HA.class "card-buttons" ]
            [ if not anticipated then
                Html.span
                    [ HE.onClick (DeselectCard card.id)
                    , HA.class "octicon octicon-x"
                    ]
                    [ Html.text "" ]

              else
                Html.text ""
            ]
        ]


isInProject : String -> Card -> Bool
isInProject name card =
    List.member name (List.map (.project >> .name) card.cards)


involvesUser : Model -> String -> Card -> Bool
involvesUser model login card =
    Maybe.withDefault [] (Dict.get card.id model.data.actors)
        |> List.any (.user >> Maybe.map .login >> (==) (Just login))


lastActivityIsByUser : Dict GitHubGraph.ID (List Backend.EventActor) -> String -> Card -> Bool
lastActivityIsByUser cardEvents login card =
    let
        events =
            Maybe.withDefault [] (Dict.get card.id cardEvents)
    in
    case List.head (List.reverse events) of
        Just { user } ->
            case user of
                Just u ->
                    u.login == login

                Nothing ->
                    False

        Nothing ->
            False


inColumn : (String -> Bool) -> List GitHubGraph.CardLocation -> Bool
inColumn match =
    List.any (Maybe.withDefault False << Maybe.map (match << .name) << .column)


isAnticipated : Model -> Card -> Bool
isAnticipated model card =
    Set.member card.id model.anticipatedCards && not (OrderedSet.member card.id model.selectedCards)


isPR : Card -> Bool
isPR card =
    case card.state of
        PullRequestState _ ->
            True

        IssueState _ ->
            False


isUntriaged : Card -> Bool
isUntriaged card =
    List.isEmpty card.cards


isMerged : Card -> Bool
isMerged card =
    card.state == PullRequestState GitHubGraph.PullRequestStateMerged


labelNames : Model -> Card -> List String
labelNames model card =
    let
        selectLabel id acc =
            case Dict.get id model.allLabels of
                Just l ->
                    l.name :: acc

                Nothing ->
                    acc
    in
    List.foldl selectLabel [] card.labels


hasLabel : Model -> String -> Card -> Bool
hasLabel model name card =
    let
        matchingLabels =
            model.allLabels
                |> Dict.filter (\_ l -> l.name == name)
    in
    List.any (\a -> Dict.member a matchingLabels) card.labels


hasLabelAndColor : Model -> String -> String -> Card -> Bool
hasLabelAndColor model name color card =
    let
        matchingLabels =
            model.allLabels
                |> Dict.filter (\_ l -> l.name == name && l.color == color)
    in
    List.any (\a -> Dict.member a matchingLabels) card.labels


isEnhancement : Card -> Bool
isEnhancement card =
    card.processState.hasEnhancementLabel


isBug : Card -> Bool
isBug card =
    card.processState.hasBugLabel


isWontfix : Card -> Bool
isWontfix card =
    card.processState.hasWontfixLabel


isPaused : Card -> Bool
isPaused card =
    card.processState.hasPausedLabel


isAcceptedPR : Card -> Bool
isAcceptedPR card =
    (isEnhancement card || isBug card) && isMerged card


isOpen : Card -> Bool
isOpen card =
    case card.state of
        IssueState GitHubGraph.IssueStateOpen ->
            True

        PullRequestState GitHubGraph.PullRequestStateOpen ->
            True

        _ ->
            False


isInFlight : Card -> Bool
isInFlight card =
    card.processState.inInFlightColumn


isDone : Card -> Bool
isDone card =
    card.processState.inDoneColumn


isBacklog : Card -> Bool
isBacklog card =
    card.processState.inBacklogColumn


isIcebox : Card -> Bool
isIcebox card =
    card.processState.inIceboxColumn


viewCard : Model -> Card -> Html Msg
viewCard model card =
    Html.div
        [ HA.classList
            [ ( "card", True )
            , ( "in-flight", isInFlight card )
            , ( "done", isDone card )
            , ( "icebox", isIcebox card )
            , ( "backlog", isBacklog card )
            , ( "paused", isPaused card )
            , ( "anticipated", isAnticipated model card )
            , ( "highlighted", model.highlightedCard == Just card.id )
            , ( activityClass model.currentTime card.updatedAt, isPR card )
            , ( "last-activity-is-me"
              , case model.me of
                    Just { user } ->
                        lastActivityIsByUser model.data.actors user.login card

                    Nothing ->
                        False
              )
            ]
        , HE.onClick (SelectCard card.id)
        , HE.onMouseOver (HighlightNode card.id)
        , HE.onMouseOut (UnhighlightNode card.id)
        ]
        [ Html.div [ HA.class "card-info" ]
            [ Html.div [ HA.class "card-actors" ] <|
                List.map (viewCardActor model) (recentActors model card)
            , Html.span
                [ HA.class "card-title"
                , HA.draggable "false"
                ]
                ([ Html.a
                    [ HA.href card.url
                    , HA.target "_blank"
                    ]
                    [ Html.text card.title
                    ]
                 ]
                    ++ externalIcons card
                )
            , Html.span [ HA.class "card-labels" ] <|
                List.map (viewLabel model) card.labels
            , Html.div [ HA.class "card-meta" ]
                [ Html.a
                    [ HA.href card.url
                    , HA.target "_blank"
                    , HA.draggable "false"
                    ]
                    [ Html.text ("#" ++ String.fromInt card.number) ]
                , Html.text " "
                , Html.text "opened by "
                , case card.author of
                    Just user ->
                        Html.a
                            [ HA.href user.url
                            , HA.target "_blank"
                            , HA.draggable "false"
                            ]
                            [ Html.text user.login ]

                    _ ->
                        Html.text "(deleted user)"
                ]
            ]
        , Html.div [ HA.class "card-icons" ]
            ([ Html.span
                [ HA.classList
                    [ ( "octicon", True )
                    , ( "open", isOpen card )
                    , ( "closed", not (isOpen card) )
                    , ( "merged", isMerged card )
                    , ( "octicon-issue-opened", card.state == IssueState GitHubGraph.IssueStateOpen )
                    , ( "octicon-issue-closed", card.state == IssueState GitHubGraph.IssueStateClosed )
                    , ( "octicon-git-pull-request", isPR card )
                    ]
                , HE.onClick
                    (if isPR card then
                        RefreshPullRequest card.id

                     else
                        RefreshIssue card.id
                    )
                ]
                []
             , case ( isInFlight card, isPaused card ) of
                ( True, True ) ->
                    Html.span
                        [ HA.class "octicon unpause octicon-bookmark"
                        , HE.onClick (UnpauseCard card)
                        ]
                        []

                ( True, False ) ->
                    Html.span
                        [ HA.class "octicon pause octicon-bookmark"
                        , HE.onClick (PauseCard card)
                        ]
                        []

                _ ->
                    Html.text ""
             ]
                ++ prIcons model card
            )
        ]


externalIcons : Card -> List (Html Msg)
externalIcons card =
    List.map
        (\{ url } ->
            Html.a
                [ HA.target "_blank"
                , HA.class "external-link octicon octicon-link-external"
                , HA.href url
                ]
                []
        )
        card.cards


prIcons : Model -> Card -> List (Html Msg)
prIcons model card =
    case card.content of
        GitHubGraph.IssueCardContent _ ->
            []

        GitHubGraph.PullRequestCardContent pr ->
            let
                statusChecks =
                    case Maybe.map .status pr.lastCommit of
                        Just (Just { contexts }) ->
                            (\a -> List.map a contexts) <|
                                \c ->
                                    Html.span
                                        [ HA.classList
                                            [ ( "status-icon", True )
                                            , ( "octicon", True )
                                            , ( case c.state of
                                                    GitHubGraph.StatusStatePending ->
                                                        "octicon-primitive-dot"

                                                    GitHubGraph.StatusStateSuccess ->
                                                        "octicon-check"

                                                    GitHubGraph.StatusStateFailure ->
                                                        "octicon-x"

                                                    GitHubGraph.StatusStateExpected ->
                                                        "octicon-question"

                                                    GitHubGraph.StatusStateError ->
                                                        "octicon-alert"
                                              , True
                                              )
                                            , ( case c.state of
                                                    GitHubGraph.StatusStatePending ->
                                                        "pending"

                                                    GitHubGraph.StatusStateSuccess ->
                                                        "success"

                                                    GitHubGraph.StatusStateFailure ->
                                                        "failure"

                                                    GitHubGraph.StatusStateExpected ->
                                                        "expected"

                                                    GitHubGraph.StatusStateError ->
                                                        "error"
                                              , True
                                              )
                                            ]
                                        ]
                                        []

                        _ ->
                            []

                reviews =
                    Maybe.withDefault [] <| Dict.get card.id model.data.reviewers

                reviewStates =
                    List.map
                        (\r ->
                            let
                                reviewClass =
                                    case r.state of
                                        GitHubGraph.PullRequestReviewStatePending ->
                                            "pending"

                                        GitHubGraph.PullRequestReviewStateApproved ->
                                            "success"

                                        GitHubGraph.PullRequestReviewStateChangesRequested ->
                                            "failure"

                                        GitHubGraph.PullRequestReviewStateCommented ->
                                            "commented"

                                        GitHubGraph.PullRequestReviewStateDismissed ->
                                            "dismissed"
                            in
                            Html.img [ HA.class ("status-actor " ++ reviewClass), HA.src r.author.avatar ] []
                        )
                        reviews

                mergeClass =
                    case pr.mergeable of
                        GitHubGraph.MergeableStateMergeable ->
                            "success"

                        GitHubGraph.MergeableStateConflicting ->
                            "failure"

                        GitHubGraph.MergeableStateUnknown ->
                            "pending"
            in
            Html.span
                [ HA.class ("status-icon octicon octicon-git-merge " ++ mergeClass) ]
                []
                :: (statusChecks ++ reviewStates)


viewNoteCard : Model -> GitHubGraph.ProjectColumn -> String -> Html Msg
viewNoteCard model col text =
    Html.div
        [ HA.classList
            [ ( "card", True )
            , ( "in-flight", detectColumn.inFlight col.name )
            , ( "done", detectColumn.done col.name )
            , ( "backlog", detectColumn.backlog col.name )
            ]
        ]
        [ Html.div [ HA.class "card-info card-note" ]
            [ Markdown.toHtml [] text ]
        , Html.div [ HA.class "card-icons" ]
            [ octicon "book"
            ]
        ]


recentActors : Model -> Card -> List Backend.EventActor
recentActors model card =
    Dict.get card.id model.data.actors
        |> Maybe.withDefault []
        |> List.reverse
        |> List.take 3
        |> List.reverse


hexRegex : Regex
hexRegex =
    Maybe.withDefault Regex.never <|
        Regex.fromString "([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})"


hexBrightness : Int -> Int
hexBrightness h =
    case compare h (0xFF // 2) of
        LT ->
            -1

        EQ ->
            0

        GT ->
            1


colorIsLight : Model -> String -> Bool
colorIsLight model hex =
    case Dict.get hex model.colorLightnessCache of
        Just res ->
            res

        Nothing ->
            computeColorIsLight (Log.debug "color lightness cache miss" hex hex)


computeColorIsLight : String -> Bool
computeColorIsLight hex =
    let
        matches =
            List.head <| Regex.find hexRegex hex
    in
    case Maybe.map .submatches matches of
        Just [ Just h1s, Just h2s, Just h3s ] ->
            case List.map ParseInt.parseIntHex [ h1s, h2s, h3s ] of
                [ Ok h1, Ok h2, Ok h3 ] ->
                    if (hexBrightness h1 + hexBrightness h2 + hexBrightness h3) > 0 then
                        True

                    else
                        False

                _ ->
                    Log.debug "invalid hex" hex <|
                        False

        _ ->
            Log.debug "invalid hex" hex <|
                False


viewLabel : Model -> GitHubGraph.ID -> Html Msg
viewLabel model id =
    let
        ( name, color ) =
            case Dict.get id model.allLabels of
                Just label ->
                    ( label.name, label.color )

                Nothing ->
                    ( "unknown", "ff00ff" )
    in
    Html.span
        ([ HA.class "label"
         , HE.onClick (searchLabel model name)
         ]
            ++ labelColorStyles model color
        )
        [ Html.span [ HA.class "label-text" ]
            [ Html.text name ]
        ]


viewCardActor : Model -> Backend.EventActor -> Html Msg
viewCardActor model { createdAt, avatar } =
    Html.img
        [ HA.class ("card-actor " ++ activityClass model.currentTime createdAt)
        , HA.src (avatar ++ "&s=88")
        , HA.draggable "false"
        ]
        []


isOrgMember : Maybe (List GitHubGraph.User) -> GitHubGraph.User -> Bool
isOrgMember users user =
    List.any (\x -> x.id == user.id) (Maybe.withDefault [] users)


subEdges : List (Graph.Edge e) -> List (List (Graph.Edge e))
subEdges =
    let
        edgesRelated edge =
            List.any (\{ from, to } -> from == edge.from || from == edge.to || to == edge.from || to == edge.to)

        go acc edges =
            case edges of
                [] ->
                    acc

                edge :: rest ->
                    let
                        ( connected, disconnected ) =
                            List.partition (edgesRelated edge) acc
                    in
                    case connected of
                        [] ->
                            go ([ edge ] :: acc) rest

                        _ ->
                            go ((edge :: List.concat connected) :: disconnected) rest
    in
    go []


subGraphs : Graph n e -> List (Graph n e)
subGraphs graph =
    let
        singletons =
            Graph.fold
                (\nc ncs ->
                    if IntDict.isEmpty nc.incoming && IntDict.isEmpty nc.outgoing then
                        nc :: ncs

                    else
                        ncs
                )
                []
                graph

        singletonGraphs =
            List.map (\a -> Graph.insert a Graph.empty) singletons

        subEdgeNodes =
            List.foldl (\edge set -> Set.insert edge.from (Set.insert edge.to set)) Set.empty

        connectedGraphs =
            graph
                |> Graph.edges
                |> subEdges
                |> List.map ((\a -> Graph.inducedSubgraph a graph) << Set.toList << subEdgeNodes)
    in
    connectedGraphs ++ singletonGraphs


nodeBounds : Graph.NodeContext (FG.ForceNode (Node a)) () -> NodeBounds
nodeBounds nc =
    let
        x =
            nc.node.label.x

        y =
            nc.node.label.y
    in
    nc.node.label.value.bounds { x = x, y = y }


moveCard : Model -> CardDestination -> GitHubGraph.ID -> Cmd Msg
moveCard model { columnId, afterId } cardId =
    case model.me of
        Just { token } ->
            GitHubGraph.moveCardAfter token columnId cardId afterId
                |> Task.attempt (CardMoved columnId)

        Nothing ->
            Cmd.none


addCard : Model -> CardDestination -> GitHubGraph.ID -> Cmd Msg
addCard model { projectId, columnId, afterId } contentId =
    case model.me of
        Just { token } ->
            case contentCardId model projectId contentId of
                Just cardId ->
                    GitHubGraph.moveCardAfter token columnId cardId afterId
                        |> Task.attempt (CardMoved columnId)

                Nothing ->
                    GitHubGraph.addContentCardAfter token columnId contentId afterId
                        |> Task.attempt (CardMoved columnId)

        Nothing ->
            Cmd.none


contentCardId : Model -> GitHubGraph.ID -> GitHubGraph.ID -> Maybe GitHubGraph.ID
contentCardId model projectId contentId =
    case Dict.get contentId model.allCards of
        Just card ->
            case List.filter ((==) projectId << .id << .project) card.cards of
                [ c ] ->
                    Just c.id

                _ ->
                    Nothing

        Nothing ->
            Nothing


findCardColumns : Model -> GitHubGraph.ID -> List GitHubGraph.ID
findCardColumns model cardId =
    Dict.foldl
        (\columnId cards columnIds ->
            if List.any ((==) cardId << .id) cards then
                columnId :: columnIds

            else
                columnIds
        )
        []
        model.data.columnCards


labelKey : SharedLabel -> ( String, String )
labelKey label =
    ( label.name, String.toLower label.color )


createLabel : Model -> GitHubGraph.Repo -> SharedLabel -> Cmd Msg
createLabel model repo label =
    case model.me of
        Just { token } ->
            GitHubGraph.createRepoLabel token repo label.name label.color
                |> Task.attempt (LabelChanged repo)

        Nothing ->
            Cmd.none


updateLabel : Model -> GitHubGraph.Repo -> GitHubGraph.Label -> SharedLabel -> Cmd Msg
updateLabel model repo label1 label2 =
    case model.me of
        Just { token } ->
            GitHubGraph.updateRepoLabel token repo label1 label2.name label2.color
                |> Task.attempt (LabelChanged repo)

        Nothing ->
            Cmd.none


deleteLabel : Model -> GitHubGraph.Repo -> GitHubGraph.Label -> Cmd Msg
deleteLabel model repo label =
    case model.me of
        Just { token } ->
            GitHubGraph.deleteRepoLabel token repo label.name
                |> Task.attempt (LabelChanged repo)

        Nothing ->
            Cmd.none


addIssueLabels : Model -> GitHubGraph.Issue -> List String -> Cmd Msg
addIssueLabels model issue labels =
    case model.me of
        Just { token } ->
            GitHubGraph.addIssueLabels token issue labels
                |> Task.attempt (DataChanged (Backend.refreshIssue issue.id IssueRefreshed))

        Nothing ->
            Cmd.none


removeIssueLabel : Model -> GitHubGraph.Issue -> String -> Cmd Msg
removeIssueLabel model issue label =
    case model.me of
        Just { token } ->
            GitHubGraph.removeIssueLabel token issue label
                |> Task.attempt (DataChanged (Backend.refreshIssue issue.id IssueRefreshed))

        Nothing ->
            Cmd.none


addPullRequestLabels : Model -> GitHubGraph.PullRequest -> List String -> Cmd Msg
addPullRequestLabels model pr labels =
    case model.me of
        Just { token } ->
            GitHubGraph.addPullRequestLabels token pr labels
                |> Task.attempt (DataChanged (Backend.refreshPR pr.id PullRequestRefreshed))

        Nothing ->
            Cmd.none


removePullRequestLabel : Model -> GitHubGraph.PullRequest -> String -> Cmd Msg
removePullRequestLabel model pr label =
    case model.me of
        Just { token } ->
            GitHubGraph.removePullRequestLabel token pr label
                |> Task.attempt (DataChanged (Backend.refreshPR pr.id PullRequestRefreshed))

        Nothing ->
            Cmd.none


randomizeColor : SharedLabel -> SharedLabel
randomizeColor label =
    let
        currentColor =
            Maybe.withDefault 0 <| Result.toMaybe <| ParseInt.parseIntHex label.color

        randomHex =
            generateColor currentColor
    in
    { label | color = randomHex }


generateColor : Int -> String
generateColor seed =
    let
        ( randomColor, _ ) =
            Random.step (Random.int 0x00 0x00FFFFFF) (Random.initialSeed seed)
    in
    String.padLeft 6 '0' (ParseInt.toHex randomColor)


finishProjectDragRefresh : Model -> Model
finishProjectDragRefresh model =
    let
        updateColumn id cards m =
            let
                data =
                    m.data
            in
            { m | data = { data | columnCards = Dict.insert id cards data.columnCards } }

        updateContent content m =
            let
                data =
                    m.data
            in
            case content of
                GitHubGraph.IssueCardContent issue ->
                    { m
                        | allCards = Dict.insert issue.id (issueCard issue) m.allCards
                        , data = { data | issues = Dict.insert issue.id issue data.issues }
                    }

                GitHubGraph.PullRequestCardContent pr ->
                    { m
                        | allCards = Dict.insert pr.id (prCard pr) m.allCards
                        , data = { data | prs = Dict.insert pr.id pr data.prs }
                    }
    in
    case model.projectDragRefresh of
        Nothing ->
            model

        Just pdr ->
            case ( ( pdr.contentId, pdr.content, pdr.sourceId ), ( pdr.sourceCards, pdr.targetId, pdr.targetCards ) ) of
                ( ( Just _, Just c, Just sid ), ( Just scs, Just tid, Just tcs ) ) ->
                    { model | projectDrag = Drag.complete model.projectDrag }
                        |> updateContent c
                        |> updateColumn sid scs
                        |> updateColumn tid tcs
                        |> computeGraph

                ( ( Just _, Just c, Nothing ), ( Nothing, Just tid, Just tcs ) ) ->
                    { model | projectDrag = Drag.complete model.projectDrag }
                        |> updateContent c
                        |> updateColumn tid tcs
                        |> computeGraph

                ( ( Just _, Just c, Just _ ), ( _, Just tid, Just tcs ) ) ->
                    { model | projectDrag = Drag.land model.projectDrag }
                        |> updateContent c
                        |> updateColumn tid tcs

                ( ( Nothing, Nothing, Just sid ), ( Just scs, Just tid, Just tcs ) ) ->
                    { model | projectDrag = Drag.complete model.projectDrag }
                        |> updateColumn sid scs
                        |> updateColumn tid tcs

                ( ( Nothing, Nothing, Nothing ), ( Nothing, Just tid, Just tcs ) ) ->
                    { model | projectDrag = Drag.complete model.projectDrag }
                        |> updateColumn tid tcs

                ( ( Nothing, Nothing, Just _ ), ( _, Just tid, Just tcs ) ) ->
                    { model | projectDrag = Drag.land model.projectDrag }
                        |> updateColumn tid tcs

                _ ->
                    model


emptyArc : Shape.Arc
emptyArc =
    { startAngle = 0
    , endAngle = 0
    , padAngle = 0
    , innerRadius = 0
    , outerRadius = 0
    , cornerRadius = 0
    , padRadius = 0
    }


octicon : String -> Html Msg
octicon label =
    Html.span [ HA.class ("octicon octicon-" ++ label) ] []
