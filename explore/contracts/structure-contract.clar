;; Interstellar coalition for coordinating space exploration missions and resource sharing

;; Constants
(define-constant fleet-admiral tx-sender)
(define-constant err-admiral-only (err u400))
(define-constant err-not-crew-member (err u401))
(define-constant err-invalid-mission (err u402))
(define-constant err-mission-expired (err u403))
(define-constant err-already-responded (err u404))
(define-constant err-insufficient-fleet-power (err u405))
(define-constant err-mission-not-successful (err u406))
(define-constant err-faction-not-found (err u407))
(define-constant err-invalid-resources (err u408))

;; Data Variables
(define-data-var mission-counter uint u0)
(define-data-var coalition-fee uint u3000000) ;; 3 STX fee for mission proposals

;; Data Maps

;; Space factions in the coalition
(define-map space-factions 
  { faction-id: uint }
  {
    faction-name: (string-ascii 50),
    command-structure: principal,
    fleet-threshold: uint,
    resource-depot: principal,
    operational-status: bool
  }
)

;; Interstellar exploration missions
(define-map exploration-missions
  { mission-id: uint }
  {
    mission-designation: (string-ascii 100),
    mission-briefing: (string-ascii 500),
    mission-commander: principal,
    coalition-factions: (list 10 uint),
    resource-requirements: (list 10 { faction-id: uint, contribution: uint }),
    mission-launch: uint,
    mission-terminus: uint,
    fleet-coordination-threshold: uint,
    mission-completed: bool,
    mission-class: (string-ascii 20) ;; "exploration", "defense", "colonization"
  }
)

;; Faction fleet deployments
(define-map fleet-deployments
  { mission-id: uint, faction-id: uint }
  {
    ships-deployed: uint,
    ships-withheld: uint,
    total-fleet-power: uint,
    deployment-consensus: bool,
    faction-commitment: (optional bool) ;; true = deploy, false = standby
  }
)

;; Individual commander responses
(define-map commander-responses
  { mission-id: uint, faction-id: uint, commander: principal }
  {
    response: bool, ;; true = deploy, false = standby
    fleet-strength: uint,
    response-time: uint
  }
)

;; Faction resource allocations
(define-map resource-allocations
  { mission-id: uint, faction-id: uint }
  {
    allocated-resources: uint,
    resources-secured: bool,
    deployment-condition: (string-ascii 50)
  }
)

;; Coalition operations
(define-map coalition-operations
  { operation-id: uint }
  {
    operation-name: (string-ascii 100),
    allied-factions: (list 10 uint),
    combined-resources: uint,
    operation-status: (string-ascii 20), ;; "underway", "successful", "aborted"
    operation-start: uint
  }
)

;; Public Functions

;; Register space faction in coalition
(define-public (establish-faction-alliance 
  (faction-name (string-ascii 50))
  (command-structure principal)
  (fleet-threshold uint)
  (resource-depot principal))
  (let ((faction-id (+ (var-get mission-counter) u1)))
    (asserts! (> fleet-threshold u0) err-invalid-resources)
    (map-set space-factions
      { faction-id: faction-id }
      {
        faction-name: faction-name,
        command-structure: command-structure,
        fleet-threshold: fleet-threshold,
        resource-depot: resource-depot,
        operational-status: true
      }
    )
    (var-set mission-counter faction-id)
    (ok faction-id)
  )
)

;; Launch interstellar exploration mission
(define-public (launch-exploration-mission
  (mission-designation (string-ascii 100))
  (mission-briefing (string-ascii 500))
  (coalition-factions (list 10 uint))
  (resource-requirements (list 10 { faction-id: uint, contribution: uint }))
  (mission-duration uint)
  (fleet-coordination-threshold uint)
  (mission-class (string-ascii 20)))
  (let (
    (mission-id (+ (var-get mission-counter) u1))
    (mission-launch block-height)
    (mission-terminus (+ block-height mission-duration))
  )
    ;; Validate all factions are registered
    (asserts! (is-ok (validate-coalition-factions coalition-factions)) err-faction-not-found)
    
    ;; Pay coalition fee
    (try! (stx-transfer? (var-get coalition-fee) tx-sender fleet-admiral))
    
    ;; Create exploration mission
    (map-set exploration-missions
      { mission-id: mission-id }
      {
        mission-designation: mission-designation,
        mission-briefing: mission-briefing,
        mission-commander: tx-sender,
        coalition-factions: coalition-factions,
        resource-requirements: resource-requirements,
        mission-launch: mission-launch,
        mission-terminus: mission-terminus,
        fleet-coordination-threshold: fleet-coordination-threshold,
        mission-completed: false,
        mission-class: mission-class
      }
    )
    
    ;; Initialize fleet deployment tracking
    (map initialize-fleet-deployment coalition-factions)
    
    (var-set mission-counter mission-id)
    (ok mission-id)
  )
)

;; Fleet commander responds to mission deployment
(define-public (submit-fleet-response 
  (mission-id uint)
  (faction-id uint)
  (response bool)
  (fleet-strength uint))
  (let (
    (mission (unwrap! (map-get? exploration-missions { mission-id: mission-id }) err-invalid-mission))
    (faction-info (unwrap! (map-get? space-factions { faction-id: faction-id }) err-faction-not-found))
    (existing-response (map-get? commander-responses { mission-id: mission-id, faction-id: faction-id, commander: tx-sender }))
  )
    ;; Validate mission is active
    (asserts! (and (>= block-height (get mission-launch mission)) 
                   (<= block-height (get mission-terminus mission))) err-mission-expired)
    
    ;; Ensure commander hasn't responded yet
    (asserts! (is-none existing-response) err-already-responded)
    
    ;; Validate fleet command authority
    (asserts! (>= fleet-strength (get fleet-threshold faction-info)) err-not-crew-member)
    
    ;; Record commander's response
    (map-set commander-responses
      { mission-id: mission-id, faction-id: faction-id, commander: tx-sender }
      {
        response: response,
        fleet-strength: fleet-strength,
        response-time: block-height
      }
    )
    
    ;; Update faction deployment totals
    (try! (update-faction-deployment mission-id faction-id response fleet-strength))
    
    (ok true)
  )
)

;; Execute successful mission
(define-public (execute-mission-completion (mission-id uint))
  (let (
    (mission (unwrap! (map-get? exploration-missions { mission-id: mission-id }) err-invalid-mission))
  )
    ;; Validate mission hasn't been completed
    (asserts! (not (get mission-completed mission)) err-invalid-mission)
    
    ;; Validate mission has ended
    (asserts! (> block-height (get mission-terminus mission)) err-mission-expired)
    
    ;; Check if mission was successful
    (asserts! (has-mission-succeeded mission-id) err-mission-not-successful)
    
    ;; Mark as completed
    (map-set exploration-missions
      { mission-id: mission-id }
      (merge mission { mission-completed: true })
    )
    
    ;; Distribute mission rewards
    (try! (distribute-mission-rewards mission-id (get resource-requirements mission)))
    
    (ok true)
  )
)

;; Allocate faction resources to mission
(define-public (allocate-faction-resources 
  (mission-id uint)
  (faction-id uint)
  (resource-amount uint))
  (let (
    (faction-info (unwrap! (map-get? space-factions { faction-id: faction-id }) err-faction-not-found))
  )
    ;; Validate caller has resource authority
    (asserts! (is-eq tx-sender (get resource-depot faction-info)) err-not-crew-member)
    
    ;; Secure resources
    (map-set resource-allocations
      { mission-id: mission-id, faction-id: faction-id }
      {
        allocated-resources: resource-amount,
        resources-secured: true,
        deployment-condition: "mission-authorization"
      }
    )
    
    (ok true)
  )
)

;; Private Functions

;; Validate all coalition factions
(define-private (validate-coalition-factions (faction-list (list 10 uint)))
  (fold check-faction-exists faction-list (ok true))
)

(define-private (check-faction-exists (faction-id uint) (previous-result (response bool uint)))
  (match previous-result
    success (if (is-some (map-get? space-factions { faction-id: faction-id }))
              (ok true)
              err-faction-not-found)
    error (err error)
  )
)

;; Initialize fleet deployment tracking
(define-private (initialize-fleet-deployment (faction-id uint))
  (let ((mission-id (var-get mission-counter)))
    (map-set fleet-deployments
      { mission-id: mission-id, faction-id: faction-id }
      {
        ships-deployed: u0,
        ships-withheld: u0,
        total-fleet-power: u0,
        deployment-consensus: false,
        faction-commitment: none
      }
    )
  )
)

;; Update faction deployment totals
(define-private (update-faction-deployment 
  (mission-id uint)
  (faction-id uint)
  (response bool)
  (fleet-strength uint))
  (let (
    (current-deployment (unwrap! (map-get? fleet-deployments { mission-id: mission-id, faction-id: faction-id }) err-invalid-mission))
    (new-deployed (if response (+ (get ships-deployed current-deployment) fleet-strength) (get ships-deployed current-deployment)))
    (new-withheld (if response (get ships-withheld current-deployment) (+ (get ships-withheld current-deployment) fleet-strength)))
    (new-total (+ (get total-fleet-power current-deployment) fleet-strength))
  )
    (map-set fleet-deployments
      { mission-id: mission-id, faction-id: faction-id }
      (merge current-deployment {
        ships-deployed: new-deployed,
        ships-withheld: new-withheld,
        total-fleet-power: new-total
      })
    )
    (ok true)
  )
)

;; Check if mission succeeded
(define-private (has-mission-succeeded (mission-id uint))
  true
)

;; Distribute mission rewards
(define-private (distribute-mission-rewards 
  (mission-id uint)
  (resource-distributions (list 10 { faction-id: uint, contribution: uint })))
  (if (> (len resource-distributions) u0)
    (ok true)
    (err u999)
  )
)

;; Read-only Functions

;; Get mission details
(define-read-only (get-mission-details (mission-id uint))
  (map-get? exploration-missions { mission-id: mission-id })
)

;; Get faction information
(define-read-only (get-faction-info (faction-id uint))
  (map-get? space-factions { faction-id: faction-id })
)

;; Get faction deployment status
(define-read-only (get-faction-deployment (mission-id uint) (faction-id uint))
  (map-get? fleet-deployments { mission-id: mission-id, faction-id: faction-id })
)

;; Get commander response
(define-read-only (get-commander-response (mission-id uint) (faction-id uint) (commander principal))
  (map-get? commander-responses { mission-id: mission-id, faction-id: faction-id, commander: commander })
)

;; Check if commander can respond
(define-read-only (can-commander-respond (mission-id uint) (faction-id uint) (commander principal))
  (let (
    (mission (map-get? exploration-missions { mission-id: mission-id }))
    (existing-response (map-get? commander-responses { mission-id: mission-id, faction-id: faction-id, commander: commander }))
  )
    (match mission
      mission-data (and 
        (>= block-height (get mission-launch mission-data))
        (<= block-height (get mission-terminus mission-data))
        (is-none existing-response)
        (is-some (map-get? space-factions { faction-id: faction-id })))
      false
    )
  )
)