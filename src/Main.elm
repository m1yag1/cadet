module Main exposing (main)

import Backend exposing (Data, Me)
import Browser
import Browser.Events
import Browser.Navigation as Nav
import Card exposing (Card)
import Colors
import Dict exposing (Dict)
import Drag
import ForceGraph as FG exposing (ForceGraph)
import GitHubGraph
import Graph exposing (Graph)
import Hash
import Html exposing (Html)
import Html.Attributes as HA
import Html.Events as HE
import Html.Keyed
import Html.Lazy
import Http
import IntDict exposing (IntDict)
import Log
import Markdown
import Octicons
import OrderedSet exposing (OrderedSet)
import ParseInt
import Path
import Project
import Random
import Regex exposing (Regex)
import Set exposing (Set)
import Shape
import Svg exposing (Svg)
import Svg.Attributes as SA
import Svg.Events as SE
import Svg.Keyed
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
    , graphs : List (ForceGraph GitHubGraph.ID)
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
    , cardGraphs : List ( CardNodeState, ForceGraph GitHubGraph.ID )
    , deletingLabels : Set ( String, String )
    , editingLabels : Dict ( String, String ) SharedLabel
    , newLabel : SharedLabel
    , newLabelColored : Bool
    , newMilestoneName : String
    , showLabelFilters : Bool
    , labelSearch : String
    , suggestedLabels : List String
    , showLabelOperations : Bool
    , cardLabelOperations : Dict String CardLabelOperation
    , releaseRepoTab : Int
    , repoPullRequestsTab : Int
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
    , labelToRepoToId : Dict String (Dict GitHubGraph.ID GitHubGraph.ID)
    , prsByRepo : Dict String ( GitHubGraph.RepoLocation, List Card )
    , releaseRepos : Dict GitHubGraph.ID ReleaseRepo
    }


type alias ReleaseRepo =
    { repo : GitHubGraph.Repo
    , nextMilestone : Maybe GitHubGraph.Milestone
    , comparison : GitHubGraph.V3Comparison
    , openPRs : List Card
    , mergedPRs : List Card
    , openIssues : List Card
    , closedIssues : List Card
    , doneCards : List Card
    , documentedCards : List Card
    , undocumentedCards : List Card
    , noImpactCards : List Card
    }


type ReleaseRepoTab
    = ToDoTab
    | DoneTab
    | DocumentedTab
    | UndocumentedTab
    | NoImpactTab


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
    { allCards : Dict GitHubGraph.ID Card
    , allLabels : Dict GitHubGraph.ID GitHubGraph.Label
    , reviewers : Dict GitHubGraph.ID (List GitHubGraph.PullRequestReview)
    , currentTime : Time.Posix
    , selectedCards : OrderedSet GitHubGraph.ID
    , anticipatedCards : Set GitHubGraph.ID
    , filteredCards : Set GitHubGraph.ID
    , highlightedNode : Maybe GitHubGraph.ID
    , me : Maybe Me
    , dataIndex : Int
    , cardEvents : Dict GitHubGraph.ID (List Backend.EventActor)
    }


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
    | GraphsFetched (Result Http.Error (Backend.Indexed (List (ForceGraph GitHubGraph.ID))))
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
    | LabelCard Card String
    | UnlabelCard Card String
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
    | SetReleaseRepoTab Int
    | SetRepoPullRequestsTab Int


type Page
    = AllProjectsPage
    | GlobalGraphPage
    | ProjectPage String
    | LabelsPage
    | ReleasePage
    | ReleaseRepoPage String
    | PullRequestsPage
    | PullRequestsRepoPage String
    | BouncePage


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
        , UP.map ReleaseRepoPage (UP.s "release" </> UP.string)
        , UP.map ReleasePage (UP.s "release")
        , UP.map PullRequestsPage (UP.s "pull-requests")
        , UP.map PullRequestsRepoPage (UP.s "pull-requests" </> UP.string)
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
            , graphs = []
            , isPolling = True
            , dataIndex = 0
            , dataView =
                { reposByLabel = Dict.empty
                , labelToRepoToId = Dict.empty
                , prsByRepo = Dict.empty
                , releaseRepos = Dict.empty
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
            , suggestedLabels = []
            , showLabelOperations = False
            , cardLabelOperations = Dict.empty
            , releaseRepoTab = 0
            , repoPullRequestsTab = 0
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
                        paged =
                            { model | page = page }

                        graphed =
                            case page of
                                GlobalGraphPage ->
                                    { paged | baseGraphFilter = Nothing }

                                ProjectPage name ->
                                    { paged | baseGraphFilter = Just (InProjectFilter name) }

                                _ ->
                                    paged
                    in
                    ( computeDataView graphed
                    , Cmd.none
                    )

                Nothing ->
                    -- 404 would be nice
                    ( model, Cmd.none )

        SetCurrentTime date ->
            ( updateGraphStates { model | currentTime = date }, Cmd.none )

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
                            if Card.isOpen card then
                                Dict.insert (String.toLower card.title) card

                            else
                                identity
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
            ( updateGraphStates
                { model
                    | cardSearch = str
                    , anticipatedCards = foundCards
                }
            , Cmd.none
            )

        SelectAnticipatedCards ->
            ( updateGraphStates
                { model
                    | anticipatedCards = Set.empty
                    , selectedCards = Set.foldr OrderedSet.insert model.selectedCards model.anticipatedCards
                }
            , Cmd.none
            )

        SelectCard id ->
            ( updateGraphStates { model | selectedCards = OrderedSet.insert id model.selectedCards }
            , Cmd.none
            )

        ClearSelectedCards ->
            ( updateGraphStates { model | selectedCards = OrderedSet.empty }
            , Cmd.none
            )

        DeselectCard id ->
            ( updateGraphStates { model | selectedCards = OrderedSet.remove id model.selectedCards }
            , Cmd.none
            )

        HighlightNode id ->
            ( updateGraphStates { model | highlightedNode = Just id }, Cmd.none )

        UnhighlightNode id ->
            ( updateGraphStates { model | highlightedNode = Nothing }, Cmd.none )

        AnticipateCardFromNode id ->
            ( updateGraphStates
                { model
                    | anticipatedCards = Set.insert id model.anticipatedCards
                    , highlightedCard = Just id
                }
            , Cmd.none
            )

        UnanticipateCardFromNode id ->
            ( updateGraphStates
                { model
                    | anticipatedCards = Set.remove id model.anticipatedCards
                    , highlightedCard = Nothing
                }
            , Cmd.none
            )

        MeFetched (Ok me) ->
            ( updateGraphStates { model | me = me }, Cmd.none )

        MeFetched (Err err) ->
            Log.debug "error fetching self" err <|
                ( model, Cmd.none )

        DataFetched (Ok { index, value }) ->
            ( if index > model.dataIndex then
                let
                    issueCards =
                        Dict.map (\_ -> Card.fromIssue) value.issues

                    prCards =
                        Dict.map (\_ -> Card.fromPR) value.prs

                    allCards =
                        Dict.union issueCards prCards

                    allLabels =
                        Dict.foldl (\_ r -> loadLabels r.labels) Dict.empty value.repos

                    colorLightnessCache =
                        Dict.foldl
                            (\_ { color } cache ->
                                Dict.insert color (computeColorIsLight color) cache
                            )
                            Dict.empty
                            allLabels
                in
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
            , Cmd.batch
                [ Backend.pollData DataFetched
                , if index > model.dataIndex then
                    Backend.fetchGraphs GraphsFetched

                  else
                    Cmd.none
                ]
            )

        DataFetched (Err err) ->
            Log.debug "error fetching data" err <|
                ( { model | isPolling = False }, Cmd.none )

        GraphsFetched (Ok { index, value }) ->
            Log.debug "graphs fetched" ( index, List.length value ) <|
                ( computeDataView { model | graphs = value }, Cmd.none )

        GraphsFetched (Err err) ->
            Log.debug "error fetching graphs" err <|
                ( model, Cmd.none )

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
                    loadLabels value.labels model.allLabels

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

        LabelCard card label ->
            case card.content of
                GitHubGraph.IssueCardContent issue ->
                    ( model, addIssueLabels model issue [ label ] )

                GitHubGraph.PullRequestCardContent pr ->
                    ( model, addPullRequestLabels model pr [ label ] )

        UnlabelCard card label ->
            case card.content of
                GitHubGraph.IssueCardContent issue ->
                    ( model, removeIssueLabel model issue label )

                GitHubGraph.PullRequestCardContent pr ->
                    ( model, removePullRequestLabel model pr label )

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
                    , allCards = Dict.insert value.id (Card.fromIssue value) model.allCards
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
                    , allCards = Dict.insert value.id (Card.fromPR value) model.allCards
                    , dataIndex = max index model.dataIndex
                }
            , Cmd.none
            )

        PullRequestRefreshed (Err err) ->
            Log.debug "failed to refresh pr" err <|
                ( model, Cmd.none )

        AddFilter filter ->
            ( sortAndFilterGraphs <|
                { model | graphFilters = filter :: model.graphFilters }
            , Cmd.none
            )

        RemoveFilter filter ->
            ( sortAndFilterGraphs <|
                { model | graphFilters = List.filter ((/=) filter) model.graphFilters }
            , Cmd.none
            )

        SetGraphSort sort ->
            ( sortAndFilterGraphs { model | graphSort = sort }, Cmd.none )

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

        SetReleaseRepoTab tab ->
            ( { model | releaseRepoTab = tab }, Cmd.none )

        SetRepoPullRequestsTab tab ->
            ( { model | repoPullRequestsTab = tab }, Cmd.none )


updateGraphStates : Model -> Model
updateGraphStates model =
    let
        newState =
            { allCards = model.allCards
            , allLabels = model.allLabels
            , reviewers = model.data.reviewers
            , currentTime = model.currentTime
            , selectedCards = model.selectedCards
            , filteredCards = Set.empty
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
                                node.label.value
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
                        ( { newState | filteredCards = s.filteredCards }, g )

                    else if isBaseGraphState model s then
                        ( s, g )

                    else
                        let
                            base =
                                baseGraphState model
                        in
                        ( { base | filteredCards = s.filteredCards }, g )
                )
                model.cardGraphs
    }


computeDataView : Model -> Model
computeDataView origModel =
    let
        addToList card entry =
            case entry of
                Nothing ->
                    Just [ card ]

                Just cards ->
                    Just (card :: cards)

        groupRepoLabels =
            Dict.foldl
                (\_ repo cbn ->
                    List.foldl
                        (\label -> Dict.update ( label.name, String.toLower label.color ) (addToList repo))
                        cbn
                        repo.labels
                )
                Dict.empty

        setRepoLabelId label repo mrc =
            case mrc of
                Just rc ->
                    Just (Dict.insert repo.id label.id rc)

                Nothing ->
                    Just (Dict.singleton repo.id label.id)

        groupLabelsToRepoToId =
            Dict.foldl
                (\_ repo lrc ->
                    List.foldl
                        (\label lrc2 ->
                            Dict.update label.name (setRepoLabelId label repo) lrc2
                        )
                        lrc
                        repo.labels
                )
                Dict.empty

        addCardAndRepo card entry =
            case entry of
                Nothing ->
                    Just ( card.repo, [ card ] )

                Just ( repo, cards ) ->
                    Just ( repo, card :: cards )

        prsByRepo =
            Dict.foldl
                (\_ card acc ->
                    if Card.isOpenPR card then
                        Dict.update card.repo.name (addCardAndRepo card) acc

                    else
                        acc
                )
                Dict.empty

        origDataView =
            origModel.dataView

        dataView =
            { origDataView
                | reposByLabel = groupRepoLabels origModel.data.repos
                , labelToRepoToId = groupLabelsToRepoToId origModel.data.repos
            }

        model =
            { origModel | suggestedLabels = [], dataView = dataView }
    in
    case model.page of
        ReleasePage ->
            { model | dataView = { dataView | releaseRepos = computeReleaseRepos model } }

        ReleaseRepoPage _ ->
            { model
                | dataView = { dataView | releaseRepos = computeReleaseRepos model }
                , suggestedLabels = [ "release/documented", "release/undocumented", "release/no-impact" ]
            }

        PullRequestsPage ->
            { model | dataView = { dataView | prsByRepo = prsByRepo model.allCards } }

        PullRequestsRepoPage _ ->
            { model
                | dataView = { dataView | prsByRepo = prsByRepo model.allCards }
                , suggestedLabels = [ "needs-test" ]
            }

        LabelsPage ->
            model

        GlobalGraphPage ->
            updateGraphStates (sortAndFilterGraphs model)

        ProjectPage _ ->
            updateGraphStates (sortAndFilterGraphs model)

        AllProjectsPage ->
            model

        BouncePage ->
            model


computeReleaseRepos : Model -> Dict String ReleaseRepo
computeReleaseRepos model =
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
                    if milestone.id == id && not (Card.isMerged card) then
                        card :: acc

                    else
                        acc

        makeReleaseRepo repoId comparison acc =
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
                                if hasLabel model "release/documented" card then
                                    { sir | documentedCards = card :: sir.documentedCards }

                                else if hasLabel model "release/undocumented" card then
                                    { sir | undocumentedCards = card :: sir.undocumentedCards }

                                else if hasLabel model "release/no-impact" card then
                                    { sir | noImpactCards = card :: sir.noImpactCards }

                                else
                                    { sir | doneCards = card :: sir.doneCards }

                            categorizeByCardState card sir =
                                case card.state of
                                    Card.IssueState GitHubGraph.IssueStateOpen ->
                                        { sir | openIssues = card :: sir.openIssues }

                                    Card.IssueState GitHubGraph.IssueStateClosed ->
                                        { sir | closedIssues = card :: sir.closedIssues }

                                    Card.PullRequestState GitHubGraph.PullRequestStateOpen ->
                                        { sir | openPRs = card :: sir.openPRs }

                                    Card.PullRequestState GitHubGraph.PullRequestStateMerged ->
                                        { sir | mergedPRs = card :: sir.mergedPRs }

                                    Card.PullRequestState GitHubGraph.PullRequestStateClosed ->
                                        -- ignored
                                        sir

                            categorizeCard card sir =
                                let
                                    byState =
                                        categorizeByCardState card sir
                                in
                                if Card.isOpen card then
                                    byState

                                else
                                    categorizeByDocumentedState card byState

                            releaseRepo =
                                List.foldl categorizeCard
                                    { repo = repo
                                    , nextMilestone = nextMilestone
                                    , comparison = comparison
                                    , openPRs = []
                                    , mergedPRs = []
                                    , openIssues = []
                                    , closedIssues = []
                                    , doneCards = []
                                    , documentedCards = []
                                    , undocumentedCards = []
                                    , noImpactCards = []
                                    }
                                    allCards
                        in
                        Dict.insert repo.name releaseRepo acc

                    Nothing ->
                        acc
    in
    Dict.foldl makeReleaseRepo Dict.empty model.data.comparisons


view : Model -> Browser.Document Msg
view model =
    { title = "Cadet"
    , body = [ viewCadet model ]
    }


viewCadet : Model -> Html Msg
viewCadet model =
    Html.div [ HA.class "cadet" ]
        [ viewNavBar model
        , Html.div [ HA.class "side-by-side" ]
            [ viewPage model
            , viewSidebar model
            ]
        ]


viewPage : Model -> Html Msg
viewPage model =
    Html.div [ HA.class "main-content" ]
        [ case model.page of
            AllProjectsPage ->
                viewAllProjectsPage model

            GlobalGraphPage ->
                viewGlobalGraphPage model

            ProjectPage name ->
                viewProjectPage model name

            LabelsPage ->
                viewLabelsPage model

            ReleasePage ->
                viewReleasePage model

            ReleaseRepoPage repoName ->
                case Dict.get repoName model.dataView.releaseRepos of
                    Just sir ->
                        viewReleaseRepoPage model sir

                    Nothing ->
                        Html.text "repo not found"

            PullRequestsPage ->
                viewPullRequestsPage model

            PullRequestsRepoPage repoName ->
                case Dict.get repoName model.dataView.prsByRepo of
                    Just ( repo, cards ) ->
                        viewRepoPullRequestsPage model repo cards

                    Nothing ->
                        Html.text "repo not found"

            BouncePage ->
                Html.text "you shouldn't see this"
        ]


viewSidebar : Model -> Html Msg
viewSidebar model =
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
    Html.div [ HA.class "main-sidebar" ]
        [ viewSidebarControls model
        , if List.isEmpty sidebarCards then
            Html.div [ HA.class "no-cards" ]
                [ Html.text "no cards selected" ]

          else
            Html.div [ HA.class "cards" ] sidebarCards
        ]


viewSidebarControls : Model -> Html Msg
viewSidebarControls model =
    let
        viewLabelOperation name color =
            let
                ( checkClass, icon, clickOperation ) =
                    case Dict.get name model.cardLabelOperations of
                        Just AddLabelOperation ->
                            ( "checked", Octicons.check octiconOpts, SetLabelOperation name RemoveLabelOperation )

                        Just RemoveLabelOperation ->
                            ( "unhecked", Octicons.plus octiconOpts, UnsetLabelOperation name )

                        Nothing ->
                            let
                                cards =
                                    List.filterMap (\a -> Dict.get a model.allCards) (OrderedSet.toList model.selectedCards)
                            in
                            if not (List.isEmpty cards) && List.all (hasLabel model name) cards then
                                ( "checked", Octicons.check octiconOpts, SetLabelOperation name RemoveLabelOperation )

                            else if List.any (hasLabel model name) cards then
                                ( "mixed", Octicons.dash octiconOpts, SetLabelOperation name AddLabelOperation )

                            else
                                ( "unchecked", Octicons.plus octiconOpts, SetLabelOperation name AddLabelOperation )
            in
            Html.div [ HA.class "label-operation" ]
                [ Html.span [ HA.class ("checkbox " ++ checkClass), HE.onClick clickOperation ]
                    [ icon ]
                , Html.span
                    ([ HA.class "label"
                     , HE.onClick (AddFilter (HasLabelFilter name color))
                     ]
                        ++ labelColorStyles model color
                    )
                    [ Html.span [ HA.class "label-text" ]
                        [ Html.text name ]
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
                [ Octicons.tag octiconOpts
                , Html.text "labels"
                ]
            , Html.span
                [ HE.onClick ClearSelectedCards
                , HA.class "clear-selected"
                ]
                [ Octicons.x octiconOpts ]
            ]
        , Html.div [ HA.classList [ ( "label-operations", True ), ( "visible", model.showLabelOperations ) ] ]
            [ Html.input [ HA.type_ "text", HA.placeholder "search labels", HE.onInput SetLabelSearch ] []
            , Html.div [ HA.class "label-options" ] labelOptions
            , Html.div [ HA.class "buttons" ]
                [ Html.div [ HA.class "button cancel", HE.onClick ToggleLabelOperations ]
                    [ Octicons.x octiconOpts
                    , Html.text "cancel"
                    ]
                , Html.div [ HA.class "button apply", HE.onClick ApplyLabelOperations ]
                    [ Octicons.check octiconOpts
                    , Html.text "apply"
                    ]
                ]
            ]
        ]


viewGlobalGraphPage : Model -> Html Msg
viewGlobalGraphPage model =
    Html.div [ HA.class "all-issues-graph" ]
        [ Html.div [ HA.class "column-title" ]
            [ Octicons.circuitBoard octiconOpts
            , Html.text "Issue Graph"
            ]
        , viewSpatialGraph model
        ]


viewSpatialGraph : Model -> Html Msg
viewSpatialGraph model =
    Html.div [ HA.class "spatial-graph" ]
        [ viewGraphControls model
        , Html.Keyed.node "div" [ HA.class "graphs" ] <|
            List.map (\( state, graph ) -> ( graphId graph, Html.Lazy.lazy2 viewGraph state graph ))
                model.cardGraphs
        ]


graphId : ForceGraph GitHubGraph.ID -> String
graphId { graph } =
    Graph.fold (\{ node } acc -> min node.label.value acc) "" graph


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
                                    [ Octicons.tag octiconOpts
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
                                    [ Octicons.tag octiconOpts
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
                [ Octicons.inbox octiconOpts
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
                [ Octicons.issueOpened octiconOpts
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
                [ Octicons.gitPullRequest octiconOpts
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
                        [ Octicons.commentDiscussion octiconOpts
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
                    [ Octicons.tag octiconOpts
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
                [ Octicons.flame octiconOpts
                , Html.text "impact"
                ]
            , Html.div
                [ HA.classList [ ( "control-setting", True ), ( "active", model.graphSort == AllActivitySort ) ]
                , HE.onClick (SetGraphSort AllActivitySort)
                ]
                [ Octicons.clock octiconOpts
                , Html.text "all activity"
                ]
            , case model.me of
                Just { user } ->
                    Html.div
                        [ HA.classList [ ( "control-setting", True ), ( "active", model.graphSort == UserActivitySort user.login ) ]
                        , HE.onClick (SetGraphSort (UserActivitySort user.login))
                        ]
                        [ Octicons.clock octiconOpts
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
            [ Html.a [ HA.class "button", HA.href "/" ]
                [ Octicons.project octiconOpts
                , Html.text "Projects"
                ]
            , Html.a [ HA.class "button", HA.href "/release" ]
                [ Octicons.milestone octiconOpts
                , Html.text "Release"
                ]
            , Html.a [ HA.class "button", HA.href "/pull-requests" ]
                [ Octicons.gitPullRequest octiconOpts
                , Html.text "PRs"
                ]
            , Html.a [ HA.class "button", HA.href "/graph" ]
                [ Octicons.circuitBoard octiconOpts
                , Html.text "Graph"
                ]
            , Html.a [ HA.class "button", HA.href "/labels" ]
                [ Octicons.tag octiconOpts
                , Html.text "Labels"
                ]
            ]
        , case model.me of
            Nothing ->
                Html.a [ HA.class "user-info", HA.href "/auth/github" ]
                    [ Octicons.signIn octiconOpts
                    , Html.text "Sign In"
                    ]

            Just { user } ->
                Html.a [ HA.class "user-info", HA.href user.url ]
                    [ Html.img [ HA.class "user-avatar", HA.src user.avatar ] []
                    , Html.text user.login
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
            findColumns Project.detectColumn.icebox

        backlogs =
            findColumns Project.detectColumn.backlog

        inFlights =
            findColumns Project.detectColumn.inFlight

        dones =
            findColumns Project.detectColumn.done
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
    Html.div [ HA.class "page-content" ]
        [ Html.div [ HA.class "page-header" ]
            [ Octicons.project octiconOpts
            , Html.text "Projects"
            ]
        , Html.div [ HA.class "projects-list" ]
            (List.map (viewProject model) statefulProjects)
        ]


viewLabelsPage : Model -> Html Msg
viewLabelsPage model =
    let
        newLabel =
            Html.div [ HA.class "new-label" ]
                [ Html.div [ HA.class "label-cell" ]
                    [ Html.div [ HA.class "label-name" ]
                        [ Html.form [ HA.class "label-edit", HE.onSubmit CreateLabel ]
                            [ Html.span
                                ([ HA.class "label-icon"
                                 , HE.onClick RandomizeNewLabelColor
                                 ]
                                    ++ labelColorStyles model model.newLabel.color
                                )
                                [ Octicons.sync octiconOpts ]
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
                            , HA.class "button"
                            ]
                            [ Octicons.plus octiconOpts ]
                        ]
                    ]
                ]

        labelRows =
            (\a -> List.map a (Dict.toList model.dataView.reposByLabel)) <|
                \( ( name, color ), repos ) ->
                    viewLabelRow model { name = name, color = color } repos
    in
    Html.div [ HA.class "page-content" ]
        [ Html.div [ HA.class "page-header" ]
            [ Octicons.tag octiconOpts
            , Html.text "Labels"
            ]
        , newLabel
        , Html.div [ HA.class "labels-table" ]
            labelRows
        ]


viewReleasePage : Model -> Html Msg
viewReleasePage model =
    let
        repos =
            Dict.values model.dataView.releaseRepos
                |> List.sortBy (.totalCommits << .comparison)
                |> List.reverse
    in
    Html.div [ HA.class "page-content" ]
        [ Html.div [ HA.class "page-header" ]
            [ Octicons.milestone octiconOpts
            , Html.text "Release"
            ]
        , Html.div [ HA.class "release-repos" ]
            (List.map (viewReleaseRepo model) repos)
        ]


viewReleaseRepoPage : Model -> ReleaseRepo -> Html Msg
viewReleaseRepoPage model sir =
    Html.div [ HA.class "page-content" ]
        [ Html.div [ HA.class "page-header" ]
            [ Html.a [ HA.href "/release" ]
                [ Octicons.milestone octiconOpts
                , Html.text "Release"
                ]
            , Octicons.repo octiconOpts
            , Html.text sir.repo.name
            , case sir.nextMilestone of
                Just nm ->
                    Html.span [ HA.class "release-next-milestone" ]
                        [ Octicons.milestone octiconOpts
                        , Html.text nm.title
                        ]

                Nothing ->
                    Html.text ""
            ]
        , viewTabbedCards model
            .releaseRepoTab
            SetReleaseRepoTab
            [ ( "To Do", sir.openIssues ++ sir.openPRs )
            , ( "Done", sir.doneCards )
            , ( "Documented", sir.documentedCards )
            , ( "Undocumented", sir.undocumentedCards )
            , ( "No Impact", sir.noImpactCards )
            ]
        ]


viewTabbedCards :
    Model
    -> (Model -> Int)
    -> (Int -> Msg)
    -> List ( String, List Card )
    -> Html Msg
viewTabbedCards model currentTab setTab tabs =
    Html.div [ HA.class "tabbed-cards" ]
        [ let
            tabAttrs tab =
                [ HA.classList [ ( "tab", True ), ( "selected", currentTab model == tab ) ]
                , HE.onClick (setTab tab)
                ]

            tabCount count =
                Html.span [ HA.class "counter" ]
                    [ Html.text (String.fromInt count) ]
          in
          Html.div [ HA.class "tab-row" ] <|
            List.indexedMap
                (\idx ( title, cards ) ->
                    Html.span (tabAttrs idx)
                        [ Html.text title
                        , tabCount (List.length cards)
                        ]
                )
                tabs
        , let
            firstTabClass =
                HA.classList [ ( "first-tab", currentTab model == 0 ) ]
          in
          case List.drop (currentTab model) tabs of
            ( _, cards ) :: _ ->
                if List.isEmpty cards then
                    Html.div [ HA.class "no-tab-cards", firstTabClass ]
                        [ Html.text "no cards" ]

                else
                    cards
                        |> List.sortBy (.updatedAt >> Time.posixToMillis)
                        |> List.reverse
                        |> List.map (viewCard model)
                        |> Html.div [ HA.class "tab-cards", firstTabClass ]

            _ ->
                Html.text ""
        ]


viewReleaseRepo : Model -> ReleaseRepo -> Html Msg
viewReleaseRepo model sir =
    Html.div [ HA.class "metrics-item" ]
        [ Html.a [ HA.class "column-title", HA.href ("/release/" ++ sir.repo.name) ]
            [ Octicons.repo octiconOpts
            , Html.text sir.repo.name
            , case sir.nextMilestone of
                Just nm ->
                    Html.span []
                        [ Octicons.milestone octiconOpts
                        , Html.text nm.title
                        ]

                Nothing ->
                    Html.text ""
            ]
        , Html.div [ HA.class "metrics" ]
            [ viewMetric
                (Octicons.gitCommit { octiconOpts | color = Colors.gray })
                sir.comparison.totalCommits
                "commits"
                "commit"
                "since last release"
            , viewMetric
                (Octicons.gitPullRequest { octiconOpts | color = Colors.purple })
                (List.length sir.mergedPRs)
                "merged PRs"
                "merged PRs"
                "since last release"
            , if List.isEmpty sir.closedIssues then
                Html.text ""

              else
                viewMetric
                    (Octicons.check { octiconOpts | color = Colors.green })
                    (List.length sir.closedIssues)
                    "closed issues"
                    "closed issue"
                    "in current milestone"
            , if List.isEmpty sir.openIssues then
                Html.text ""

              else
                viewMetric
                    (Octicons.issueOpened { octiconOpts | color = Colors.yellow })
                    (List.length sir.openIssues)
                    "open issues"
                    "open issue"
                    "in current milestone"
            ]
        ]


viewPullRequestsPage : Model -> Html Msg
viewPullRequestsPage model =
    let
        viewRepoPRs repo prs =
            Html.div [ HA.class "repo-pull-requests" ]
                [ Html.a [ HA.class "column-title", HA.href ("/pull-requests/" ++ repo.name) ]
                    [ Octicons.repo octiconOpts
                    , Html.text repo.name
                    ]
                , prs
                    |> List.sortBy (.updatedAt >> Time.posixToMillis)
                    |> List.reverse
                    |> List.map (viewCard model)
                    |> Html.div [ HA.class "cards" ]
                ]
    in
    Html.div [ HA.class "page-content" ]
        [ Html.div [ HA.class "page-header" ]
            [ Octicons.gitPullRequest octiconOpts
            , Html.text "Pull Requests"
            ]
        , Dict.values model.dataView.prsByRepo
            |> List.sortBy (Tuple.second >> List.length)
            |> List.reverse
            |> List.map (\( a, b ) -> viewRepoPRs a b)
            |> Html.div [ HA.class "pull-request-columns" ]
        ]


type alias CategorizedRepoPRs =
    { inbox : List Card
    , failedChecks : List Card
    , needsTest : List Card
    , mergeConflict : List Card
    , changesRequested : List Card
    }


failedChecks : Card -> Bool
failedChecks card =
    case card.content of
        GitHubGraph.PullRequestCardContent { lastCommit } ->
            case lastCommit |> Maybe.andThen .status of
                Just { contexts } ->
                    List.any ((==) GitHubGraph.StatusStateFailure << .state) contexts

                Nothing ->
                    False

        _ ->
            False


changesRequested : Model -> Card -> Bool
changesRequested model card =
    case Dict.get card.id model.data.reviewers of
        Just reviews ->
            List.any ((==) GitHubGraph.PullRequestReviewStateChangesRequested << .state) reviews

        _ ->
            False


hasMergeConflict : Card -> Bool
hasMergeConflict card =
    case card.content of
        GitHubGraph.PullRequestCardContent { mergeable } ->
            case mergeable of
                GitHubGraph.MergeableStateMergeable ->
                    False

                GitHubGraph.MergeableStateConflicting ->
                    True

                GitHubGraph.MergeableStateUnknown ->
                    False

        _ ->
            False


viewRepoPullRequestsPage : Model -> GitHubGraph.RepoLocation -> List Card -> Html Msg
viewRepoPullRequestsPage model repo prCards =
    let
        categorizeCard card cat =
            if hasLabel model "needs-test" card then
                { cat | needsTest = card :: cat.needsTest }

            else if changesRequested model card then
                { cat | changesRequested = card :: cat.changesRequested }

            else if failedChecks card then
                { cat | failedChecks = card :: cat.failedChecks }

            else if hasMergeConflict card then
                { cat | mergeConflict = card :: cat.mergeConflict }

            else
                { cat | inbox = card :: cat.inbox }

        categorized =
            List.foldl categorizeCard
                { inbox = []
                , failedChecks = []
                , needsTest = []
                , mergeConflict = []
                , changesRequested = []
                }
                prCards
    in
    Html.div [ HA.class "page-content" ]
        [ Html.div [ HA.class "page-header" ]
            [ Html.div []
                [ Html.a [ HA.href "/pull-requests" ]
                    [ Octicons.gitPullRequest octiconOpts
                    , Html.text "Pull Requests"
                    ]
                , Octicons.repo octiconOpts
                , Html.text repo.name
                ]
            ]
        , Html.div [ HA.class "repo-pull-requests" ]
            [ viewTabbedCards model
                .repoPullRequestsTab
                SetRepoPullRequestsTab
                [ ( "Inbox", categorized.inbox )
                , ( "Failed Checks", categorized.failedChecks )
                , ( "Merge Conflict", categorized.mergeConflict )
                , ( "Needs Tests", categorized.needsTest )
                , ( "Changes Requested", categorized.changesRequested )
                ]
            ]
        ]


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
                    if Card.isOpen c && includesLabel model label c.labels then
                        if Card.isPR c then
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
                                    ([ HA.class "label-icon"
                                     , HE.onClick (searchLabel model label.name)
                                     ]
                                        ++ labelColorStyles model label.color
                                    )
                                    [ Octicons.tag octiconOpts ]

                              else
                                Html.span
                                    ([ HA.class "label-icon"
                                     , HE.onClick (SetLabelColor label.color)
                                     ]
                                        ++ labelColorStyles model label.color
                                    )
                                    [ Octicons.paintcan octiconOpts ]
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
                                ([ HA.class "label-icon"
                                 , HE.onClick (RandomizeLabelColor label)
                                 ]
                                    ++ labelColorStyles model newLabel.color
                                )
                                [ Octicons.sync octiconOpts ]
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
                    [ Octicons.issueOpened octiconOpts
                    , Html.span [ HA.class "count-number" ]
                        [ Html.text (String.fromInt (List.length issues))
                        ]
                    ]
                ]
            ]
        , Html.div [ HA.class "label-cell" ]
            [ Html.div [ HA.class "label-counts" ]
                [ Html.span [ HA.class "count" ]
                    [ Octicons.gitPullRequest octiconOpts
                    , Html.span [ HA.class "count-number" ]
                        [ Html.text (String.fromInt (List.length prs))
                        ]
                    ]
                ]
            ]
        , Html.div [ HA.class "label-cell" ]
            [ Html.div [ HA.class "label-counts last" ]
                [ Html.span [ HA.class "count", HA.title (String.join ", " (List.map .name repos)) ]
                    [ Octicons.repo octiconOpts
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
                    , HA.class "button"
                    ]
                    [ Octicons.mirror octiconOpts ]
                , if Dict.member stateKey model.editingLabels then
                    Html.span
                        [ HE.onClick (StopEditingLabel label)
                        , HA.class "button"
                        ]
                        [ Octicons.x octiconOpts ]

                  else
                    Html.span
                        [ HE.onClick (StartEditingLabel label)
                        , HA.class "button"
                        ]
                        [ Octicons.pencil octiconOpts ]
                , if Set.member stateKey model.deletingLabels then
                    Html.span
                        [ HE.onClick (StopDeletingLabel label)
                        , HA.class "button close"
                        ]
                        [ Octicons.x octiconOpts ]

                  else
                    Html.span
                        [ HE.onClick (StartDeletingLabel label)
                        , HA.class "button"
                        ]
                        [ Octicons.trashcan octiconOpts ]
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
                        , HA.class "button delete"
                        ]
                        [ Octicons.check octiconOpts ]

                  else
                    Html.span
                        [ HE.onClick (EditLabel label)
                        , HA.class "button edit"
                        ]
                        [ Octicons.check octiconOpts ]
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
    , if colorIsLight model color then
        HA.class "light-label"

      else
        HA.class "dark-label"
    ]


onlyOpenCards : Model -> List Backend.ColumnCard -> List Backend.ColumnCard
onlyOpenCards model =
    List.filter <|
        \{ contentId } ->
            case contentId of
                Just id ->
                    case Dict.get id model.allCards of
                        Just card ->
                            Card.isOpen card

                        Nothing ->
                            False

                Nothing ->
                    False


viewMetric : Html Msg -> Int -> String -> String -> String -> Html Msg
viewMetric icon count plural singular description =
    Html.div [ HA.class "metric" ]
        [ icon
        , Html.span [ HA.class "count" ] [ Html.text (String.fromInt count) ]
        , Html.text " "
        , Html.text <|
            if count == 1 then
                singular

            else
                plural
        , Html.text " "
        , Html.text description
        ]


viewProject : Model -> ProjectState -> Html Msg
viewProject model { project, backlogs, inFlight, done } =
    let
        cardCount column =
            Dict.get column.id model.data.columnCards
                |> Maybe.map (List.length << onlyOpenCards model)
                |> Maybe.withDefault 0
    in
    Html.div [ HA.class "metrics-item" ]
        [ Html.a [ HA.class "column-title", HA.href ("/projects/" ++ project.name) ]
            [ Octicons.project octiconOpts
            , Html.text project.name
            ]
        , Html.div [ HA.class "metrics" ]
            [ viewMetric
                (Octicons.book { octiconOpts | color = Colors.gray })
                (List.sum (List.map cardCount backlogs))
                "stories"
                "story"
                "scheduled"
            , viewMetric
                (Octicons.pulse { octiconOpts | color = Colors.yellow })
                (cardCount inFlight)
                "stories"
                "story"
                "in-flight"
            , viewMetric
                (Octicons.check { octiconOpts | color = Colors.green })
                (cardCount done)
                "stories"
                "story"
                "done"
            ]
        ]


viewProjectColumn : Model -> GitHubGraph.Project -> (List Backend.ColumnCard -> List Backend.ColumnCard) -> Html Msg -> GitHubGraph.ProjectColumn -> Html Msg
viewProjectColumn model project mod icon col =
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
        [ Html.div [ HA.class "column-title" ]
            [ icon
            , Html.text col.name
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
        [ Html.div [ HA.class "icebox-graph" ]
            [ Html.div [ HA.class "column-title" ]
                [ Octicons.circuitBoard octiconOpts
                , Html.text (project.name ++ " Graph")
                ]
            , viewSpatialGraph model
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
        , Html.div [ HA.class "project-columns" ]
            ([ Html.div [ HA.class "column done-column" ]
                [ viewProjectColumn model project (onlyOpenCards model) (Octicons.check octiconOpts) done ]
             , Html.div [ HA.class "column in-flight-column" ]
                [ viewProjectColumn model project identity (Octicons.pulse octiconOpts) inFlight ]
             ]
                ++ List.map
                    (\backlog ->
                        Html.div [ HA.class "column backlog-column" ]
                            [ viewProjectColumn model project identity (Octicons.book octiconOpts) backlog ]
                    )
                    backlogs
            )
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


sortAndFilterGraphs : Model -> Model
sortAndFilterGraphs model =
    let
        allFilters =
            case model.baseGraphFilter of
                Just f ->
                    f :: model.graphFilters

                Nothing ->
                    model.graphFilters

        baseState =
            baseGraphState model

        filteredGraphs =
            List.foldl
                (\fg fgs ->
                    let
                        matching =
                            Graph.fold
                                (\{ node } matches ->
                                    case Dict.get node.label.value model.allCards of
                                        Just card ->
                                            if satisfiesFilters model allFilters card then
                                                Set.insert card.id matches

                                            else
                                                matches

                                        Nothing ->
                                            matches
                                )
                                Set.empty
                                fg.graph
                    in
                    if Set.isEmpty matching then
                        fgs

                    else
                        ( { baseState | filteredCards = matching }, fg ) :: fgs
                )
                []
                model.graphs

        sortFunc ( _, a ) ( _, b ) =
            case model.graphSort of
                ImpactSort ->
                    graphImpactCompare model a b

                UserActivitySort login ->
                    graphUserActivityCompare model login a b

                AllActivitySort ->
                    graphAllActivityCompare model a b

        graphs =
            filteredGraphs
                |> List.sortWith sortFunc
                |> List.reverse
    in
    { model | cardGraphs = graphs }


baseGraphState : Model -> CardNodeState
baseGraphState model =
    { allCards = model.allCards
    , allLabels = model.allLabels
    , reviewers = model.data.reviewers
    , currentTime = model.currentTime
    , me = model.me
    , dataIndex = model.dataIndex
    , cardEvents = model.data.actors
    , selectedCards = OrderedSet.empty
    , anticipatedCards = Set.empty
    , filteredCards = Set.empty
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
            Card.isPR card

        IssuesFilter ->
            not (Card.isPR card)

        UntriagedFilter ->
            Card.isUntriaged card


graphImpactCompare : Model -> ForceGraph GitHubGraph.ID -> ForceGraph GitHubGraph.ID -> Order
graphImpactCompare model a b =
    case compare (Graph.size a.graph) (Graph.size b.graph) of
        EQ ->
            let
                graphScore =
                    Graph.fold
                        (\{ node } sum ->
                            case Dict.get node.label.value model.allCards of
                                Just { score } ->
                                    score + sum

                                Nothing ->
                                    sum
                        )
                        0
            in
            compare (graphScore a.graph) (graphScore b.graph)

        x ->
            x


graphUserActivityCompare : Model -> String -> ForceGraph GitHubGraph.ID -> ForceGraph GitHubGraph.ID -> Order
graphUserActivityCompare model login a b =
    let
        latestUserActivity =
            Graph.fold
                (\{ node } latest ->
                    let
                        mlatest =
                            Maybe.withDefault [] (Dict.get node.label.value model.data.actors)
                                |> List.filter (.user >> Maybe.map .login >> (==) (Just login))
                                |> List.map (.createdAt >> Time.posixToMillis)
                                |> List.maximum
                    in
                    case mlatest of
                        Nothing ->
                            latest

                        Just activity ->
                            max activity latest
                )
                0
    in
    compare (latestUserActivity a.graph) (latestUserActivity b.graph)


graphAllActivityCompare : Model -> ForceGraph GitHubGraph.ID -> ForceGraph GitHubGraph.ID -> Order
graphAllActivityCompare model a b =
    let
        latestActivity =
            Graph.fold
                (\{ node } latest ->
                    let
                        mlatest =
                            Maybe.withDefault [] (Dict.get node.label.value model.data.actors)
                                |> List.map (.createdAt >> Time.posixToMillis)
                                |> List.maximum

                        mupdated =
                            Dict.get node.label.value model.allCards
                                |> Maybe.map (.updatedAt >> Time.posixToMillis)
                    in
                    case ( mlatest, mupdated ) of
                        ( Just activity, _ ) ->
                            max activity latest

                        ( Nothing, Just updated ) ->
                            max updated latest

                        ( Nothing, Nothing ) ->
                            latest
                )
                0
    in
    compare (latestActivity a.graph) (latestActivity b.graph)


viewGraph : CardNodeState -> ForceGraph GitHubGraph.ID -> Html Msg
viewGraph state { graph } =
    let
        ( flairs, nodes, bounds ) =
            Graph.fold (viewNodeLowerUpper state) ( [], [], [] ) graph

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
            List.map (linkPath state graph) (Graph.edges graph)
    in
    Svg.svg
        [ SA.width (String.fromFloat width ++ "px")
        , SA.style "max-width: 95%"
        , SA.height "auto"
        , SA.viewBox (String.fromFloat minX ++ " " ++ String.fromFloat minY ++ " " ++ String.fromFloat width ++ " " ++ String.fromFloat height)
        ]
        [ Svg.g [ SA.class "links" ] links
        , Svg.Keyed.node "g" [ SA.class "lower" ] flairs
        , Svg.Keyed.node "g" [ SA.class "upper" ] nodes
        ]


viewNodeLowerUpper :
    CardNodeState
    -> Graph.NodeContext (FG.ForceNode GitHubGraph.ID) ()
    -> ( List ( String, Svg Msg ), List ( String, Svg Msg ), List NodeBounds )
    -> ( List ( String, Svg Msg ), List ( String, Svg Msg ), List NodeBounds )
viewNodeLowerUpper state { node, incoming, outgoing } ( fs, ns, bs ) =
    case Dict.get node.label.value state.allCards of
        Just card ->
            let
                context =
                    { incoming = incoming, outgoing = outgoing }

                pos =
                    { x = node.label.x, y = node.label.y }

                radiiWithFlair =
                    cardRadiusWithFlair card context

                bounds =
                    { x1 = node.label.x - radiiWithFlair
                    , y1 = node.label.y - radiiWithFlair
                    , x2 = node.label.x + radiiWithFlair
                    , y2 = node.label.y + radiiWithFlair
                    }
            in
            ( ( node.label.value, Svg.Lazy.lazy4 viewCardFlair card context pos state ) :: fs
            , ( node.label.value, Svg.Lazy.lazy4 viewCardCircle card context pos state ) :: ns
            , bounds :: bs
            )

        Nothing ->
            ( fs, ns, bs )


viewCardFlair : Card -> GraphContext -> Position -> CardNodeState -> Svg Msg
viewCardFlair card context pos state =
    let
        flairArcs =
            reactionFlairArcs (Maybe.withDefault [] <| Dict.get card.id state.reviewers) card context

        radii =
            { base = cardRadiusBase card context
            , withoutFlair = cardRadiusWithoutFlair card context
            , withFlair = cardRadiusWithFlair card context
            }
    in
    viewCardNodeFlair card radii flairArcs pos state


viewCardCircle : Card -> GraphContext -> Position -> CardNodeState -> Svg Msg
viewCardCircle card context pos state =
    let
        labelArcs =
            cardLabelArcs state.allLabels card context

        radii =
            { base = cardRadiusBase card context
            , withoutFlair = cardRadiusWithoutFlair card context
            , withFlair = cardRadiusWithFlair card context
            }

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
    in
    viewCardNode card radii circle labelArcs pos state


isFilteredOut : CardNodeState -> GitHubGraph.ID -> Bool
isFilteredOut state id =
    not (Set.isEmpty state.filteredCards) && not (Set.member id state.filteredCards)


linkPath : CardNodeState -> Graph (FG.ForceNode GitHubGraph.ID) () -> Graph.Edge () -> Svg Msg
linkPath state graph edge =
    let
        getEnd end =
            case Maybe.map (.node >> .label) (Graph.get end graph) of
                Just { x, y, value } ->
                    ( { x = x, y = y }, isFilteredOut state value )

                Nothing ->
                    ( { x = 0, y = 0 }, False )

        ( source, sourceIsFilteredOut ) =
            getEnd edge.from

        ( target, targetIsFilteredOut ) =
            getEnd edge.to
    in
    Svg.line
        [ SA.class "graph-edge"
        , if sourceIsFilteredOut || targetIsFilteredOut then
            SA.class "filtered-out"

          else
            SA.class "filtered-in"
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
    20
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
                                            ( Html.span [ HA.class "status-icon" ]
                                                [ case c.state of
                                                    GitHubGraph.StatusStatePending ->
                                                        Octicons.primitiveDot { octiconOpts | color = Colors.yellow }

                                                    GitHubGraph.StatusStateSuccess ->
                                                        Octicons.check { octiconOpts | color = Colors.green }

                                                    GitHubGraph.StatusStateFailure ->
                                                        Octicons.x { octiconOpts | color = Colors.red }

                                                    GitHubGraph.StatusStateExpected ->
                                                        Octicons.question { octiconOpts | color = Colors.purple }

                                                    GitHubGraph.StatusStateError ->
                                                        Octicons.alert { octiconOpts | color = Colors.orange }
                                                ]
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
                    ( Html.span [ HA.class "status-icon" ] [ Octicons.gitMerge octiconOpts ]
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
                        (( Octicons.comment octiconOpts, "comments", card.commentCount ) :: emojiReactions)
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

        isFiltered =
            isFilteredOut state card.id

        scale =
            if isHighlighted then
                "1.1"

            else if isFiltered then
                "0.5"

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
            [ "flair"
            , activityClass state.currentTime card.updatedAt
            , if isFiltered then
                "filtered-out"

              else
                "filtered-in"
            ]
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

        isFiltered =
            isFilteredOut state card.id

        scale =
            if isHighlighted then
                "1.1"

            else if isFiltered then
                "0.5"

            else
                "1"
    in
    Svg.g
        [ SA.transform ("translate(" ++ String.fromFloat x ++ "," ++ String.fromFloat y ++ ") scale(" ++ scale ++ ")")
        , if Card.isInFlight card then
            SA.class "in-flight"

          else if Card.isDone card then
            SA.class "done"

          else if Card.isIcebox card then
            SA.class "icebox"

          else if Card.isBacklog card then
            SA.class "backlog"

          else
            SA.class "untriaged"
        , if isFiltered then
            SA.class "filtered-out"

          else
            SA.class "filtered-in"
        , SE.onMouseOver (AnticipateCardFromNode card.id)
        , SE.onMouseOut (UnanticipateCardFromNode card.id)
        , SE.onClick
            (if isSelected then
                DeselectCard card.id

             else
                SelectCard card.id
            )
        ]
        (circle :: labels)


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
                    ]
                    [ Octicons.x octiconOpts ]

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


isAnticipated : Model -> Card -> Bool
isAnticipated model card =
    Set.member card.id model.anticipatedCards && not (OrderedSet.member card.id model.selectedCards)


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
        mlabelId =
            Dict.get name model.dataView.labelToRepoToId
                |> Maybe.andThen (Dict.get card.repo.id)
    in
    case mlabelId of
        Just id ->
            List.member id card.labels

        Nothing ->
            False


hasLabelAndColor : Model -> String -> String -> Card -> Bool
hasLabelAndColor model name color card =
    let
        matchingLabels =
            model.allLabels
                |> Dict.filter (\_ l -> l.name == name && l.color == color)
    in
    List.any (\a -> Dict.member a matchingLabels) card.labels


viewCard : Model -> Card -> Html Msg
viewCard model card =
    Html.div
        [ HA.classList
            [ ( "card", True )
            , ( "in-flight", Card.isInFlight card )
            , ( "done", Card.isDone card )
            , ( "icebox", Card.isIcebox card )
            , ( "backlog", Card.isBacklog card )
            , ( "paused", Card.isPaused card )
            , ( "anticipated", isAnticipated model card )
            , ( "highlighted", model.highlightedCard == Just card.id )
            , ( activityClass model.currentTime card.updatedAt, Card.isPR card )
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
                    ++ List.map (viewSuggestedLabel model card) model.suggestedLabels
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
                [ HE.onClick
                    (if Card.isPR card then
                        RefreshPullRequest card.id

                     else
                        RefreshIssue card.id
                    )
                ]
                [ if Card.isPR card then
                    Octicons.gitPullRequest
                        { octiconOpts
                            | color =
                                if Card.isMerged card then
                                    Colors.purple

                                else if Card.isOpen card then
                                    Colors.green

                                else
                                    Colors.red
                        }

                  else if Card.isOpen card then
                    Octicons.issueOpened { octiconOpts | color = Colors.green }

                  else
                    Octicons.issueClosed { octiconOpts | color = Colors.red }
                ]
             , case ( Card.isInFlight card, Card.isPaused card ) of
                ( _, True ) ->
                    Html.span
                        [ HA.class "pause-toggle"
                        , HE.onClick (UnlabelCard card "paused")
                        ]
                        [ Octicons.bookmark { octiconOpts | color = Colors.gray300 }
                        ]

                ( True, False ) ->
                    Html.span
                        [ HA.class "pause-toggle"
                        , HE.onClick (LabelCard card "paused")
                        ]
                        [ Octicons.bookmark { octiconOpts | color = Colors.gray600 }
                        ]

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
                , HA.class "external-link"
                , HA.href url
                ]
                [ Octicons.linkExternal octiconOpts ]
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
                                    let
                                        color =
                                            case c.state of
                                                GitHubGraph.StatusStatePending ->
                                                    Colors.yellow

                                                GitHubGraph.StatusStateSuccess ->
                                                    Colors.green

                                                GitHubGraph.StatusStateFailure ->
                                                    Colors.red

                                                GitHubGraph.StatusStateExpected ->
                                                    Colors.purple

                                                GitHubGraph.StatusStateError ->
                                                    Colors.orange
                                    in
                                    Html.span [ HA.class "status-icon" ]
                                        [ case c.state of
                                            GitHubGraph.StatusStatePending ->
                                                Octicons.primitiveDot { octiconOpts | color = color }

                                            GitHubGraph.StatusStateSuccess ->
                                                Octicons.check { octiconOpts | color = color }

                                            GitHubGraph.StatusStateFailure ->
                                                Octicons.x { octiconOpts | color = color }

                                            GitHubGraph.StatusStateExpected ->
                                                Octicons.question { octiconOpts | color = color }

                                            GitHubGraph.StatusStateError ->
                                                Octicons.alert { octiconOpts | color = color }
                                        ]

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
            in
            Octicons.gitMerge
                { octiconOpts
                    | color =
                        case pr.mergeable of
                            GitHubGraph.MergeableStateMergeable ->
                                Colors.green

                            GitHubGraph.MergeableStateConflicting ->
                                Colors.red

                            GitHubGraph.MergeableStateUnknown ->
                                Colors.yellow
                }
                :: (statusChecks ++ reviewStates)


viewNoteCard : Model -> GitHubGraph.ProjectColumn -> String -> Html Msg
viewNoteCard model col text =
    Html.div
        [ HA.classList
            [ ( "card", True )
            , ( "in-flight", Project.detectColumn.inFlight col.name )
            , ( "done", Project.detectColumn.done col.name )
            , ( "backlog", Project.detectColumn.backlog col.name )
            ]
        ]
        [ Html.div [ HA.class "card-info card-note" ]
            [ Markdown.toHtml [] text ]
        , Html.div [ HA.class "card-icons" ]
            [ Octicons.book octiconOpts
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
            Log.debug "color lightness cache miss" hex <|
                computeColorIsLight hex


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


viewSuggestedLabel : Model -> Card -> String -> Html Msg
viewSuggestedLabel model card name =
    let
        mlabelId =
            Dict.get name model.dataView.labelToRepoToId
                |> Maybe.andThen (Dict.get card.repo.id)

        mlabel =
            mlabelId
                |> Maybe.andThen (\id -> Dict.get id model.allLabels)

        has =
            case mlabelId of
                Just id ->
                    List.member id card.labels

                Nothing ->
                    False
    in
    case mlabel of
        Nothing ->
            Html.text ""

        Just { color } ->
            Html.span
                ([ HA.class "label suggested"
                 , HE.onClick <|
                    if has then
                        UnlabelCard card name

                    else
                        LabelCard card name
                 ]
                    ++ labelColorStyles model color
                )
                [ if has then
                    Octicons.dash { octiconOpts | color = Colors.white }

                  else
                    Octicons.plus { octiconOpts | color = Colors.white }
                , Html.span [ HA.class "label-text" ]
                    [ Html.text name ]
                ]


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
        , HA.src <|
            if String.contains "?" avatar then
                avatar ++ "&s=88"

            else
                avatar ++ "?s=88"
        , HA.draggable "false"
        ]
        []


isOrgMember : Maybe (List GitHubGraph.User) -> GitHubGraph.User -> Bool
isOrgMember users user =
    List.any (\x -> x.id == user.id) (Maybe.withDefault [] users)


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
                        | allCards = Dict.insert issue.id (Card.fromIssue issue) m.allCards
                        , data = { data | issues = Dict.insert issue.id issue data.issues }
                    }

                GitHubGraph.PullRequestCardContent pr ->
                    { m
                        | allCards = Dict.insert pr.id (Card.fromPR pr) m.allCards
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

                ( ( Just _, Just c, Nothing ), ( Nothing, Just tid, Just tcs ) ) ->
                    { model | projectDrag = Drag.complete model.projectDrag }
                        |> updateContent c
                        |> updateColumn tid tcs

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


octiconOpts : Octicons.Options
octiconOpts =
    Octicons.defaultOptions


loadLabels : List GitHubGraph.Label -> Dict GitHubGraph.ID GitHubGraph.Label -> Dict GitHubGraph.ID GitHubGraph.Label
loadLabels labels all =
    List.foldl (\l -> Dict.insert l.id { l | color = String.toLower l.color }) all labels
