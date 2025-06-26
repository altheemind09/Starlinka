;; Galactic Fleet Command - Stage 1
;; Basic fleet management and mission coordination

;; Constants
(define-constant fleet-admiral tx-sender)
(define-constant err-admiral-only (err u400))
(define-constant err-not-crew-member (err u401))
(define-constant err-invalid-mission (err u402))
(define-constant err-mission-expired (err u403))

;; Data Variables
(define-data-var mission-counter uint u0)

;; Data Maps

;; Basic space factions
(define-map space-factions 
  { faction-id: uint }
  {
    faction-name: (string-ascii 50),
    command-structure: principal,
    operational-status: bool
  }
)

;; Simple exploration missions
(define-map exploration-missions
  { mission-id: uint }
  {
    mission-designation: (string-ascii 100),
    mission-briefing: (string-ascii 500),
    mission-commander: principal,
    coalition-factions: (list 5 uint),
    mission-launch: uint,
    mission-terminus: uint,
    mission-completed: bool
  }
)

;; Basic fleet responses
(define-map fleet-responses
  { mission-id: uint, faction-id: uint }
  {
    response: bool, ;; true = deploy, false = standby
    response-time: uint
  }
)

;; Public Functions

;; Register space faction
(define-public (establish-faction-alliance 
  (faction-name (string-ascii 50))
  (command-structure principal))
  (let ((faction-id (+ (var-get mission-counter) u1)))
    (map-set space-factions
      { faction-id: faction-id }
      {
        faction-name: faction-name,
        command-structure: command-structure,
        operational-status: true
      }
    )
    (var-set mission-counter faction-id)
    (ok faction-id)
  )
)

;; Launch basic exploration mission
(define-public (launch-exploration-mission
  (mission-designation (string-ascii 100))
  (mission-briefing (string-ascii 500))
  (coalition-factions (list 5 uint))
  (mission-duration uint))
  (let (
    (mission-id (+ (var-get mission-counter) u1))
    (mission-launch block-height)
    (mission-terminus (+ block-height mission-duration))
  )
    ;; Validate all factions exist
    (asserts! (is-ok (validate-coalition-factions coalition-factions)) err-invalid-mission)
    
    ;; Create exploration mission
    (map-set exploration-missions
      { mission-id: mission-id }
      {
        mission-designation: mission-designation,
        mission-briefing: mission-briefing,
        mission-commander: tx-sender,
        coalition-factions: coalition-factions,
        mission-launch: mission-launch,
        mission-terminus: mission-terminus,
        mission-completed: false
      }
    )
    
    (var-set mission-counter mission-id)
    (ok mission-id)
  )
)

;; Submit fleet response to mission
(define-public (submit-fleet-response 
  (mission-id uint)
  (faction-id uint)
  (response bool))
  (let (
    (mission (unwrap! (map-get? exploration-missions { mission-id: mission-id }) err-invalid-mission))
    (faction-info (unwrap! (map-get? space-factions { faction-id: faction-id }) err-invalid-mission))
  )
    ;; Validate mission is active
    (asserts! (and (>= block-height (get mission-launch mission)) 
                   (<= block-height (get mission-terminus mission))) err-mission-expired)
    
    ;; Validate faction command authority
    (asserts! (is-eq tx-sender (get command-structure faction-info)) err-not-crew-member)
    
    ;; Record fleet response
    (map-set fleet-responses
      { mission-id: mission-id, faction-id: faction-id }
      {
        response: response,
        response-time: block-height
      }
    )
    
    (ok true)
  )
)

;; Complete mission
(define-public (complete-mission (mission-id uint))
  (let (
    (mission (unwrap! (map-get? exploration-missions { mission-id: mission-id }) err-invalid-mission))
  )
    ;; Only mission commander can complete
    (asserts! (is-eq tx-sender (get mission-commander mission)) err-not-crew-member)
    
    ;; Validate mission has ended
    (asserts! (> block-height (get mission-terminus mission)) err-mission-expired)
    
    ;; Mark as completed
    (map-set exploration-missions
      { mission-id: mission-id }
      (merge mission { mission-completed: true })
    )
    
    (ok true)
  )
)

;; Private Functions

;; Validate coalition factions
(define-private (validate-coalition-factions (faction-list (list 5 uint)))
  (fold check-faction-exists faction-list (ok true))
)

(define-private (check-faction-exists (faction-id uint) (previous-result (response bool uint)))
  (match previous-result
    success (if (is-some (map-get? space-factions { faction-id: faction-id }))
              (ok true)
              err-invalid-mission)
    error (err error)
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

;; Get fleet response
(define-read-only (get-fleet-response (mission-id uint) (faction-id uint))
  (map-get? fleet-responses { mission-id: mission-id, faction-id: faction-id })
)

;; Check if faction can respond
(define-read-only (can-faction-respond (mission-id uint) (faction-id uint))
  (let (
    (mission (map-get? exploration-missions { mission-id: mission-id }))
    (existing-response (map-get? fleet-responses { mission-id: mission-id, faction-id: faction-id }))
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